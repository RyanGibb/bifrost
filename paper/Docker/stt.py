import os
import sys
import time
import signal

import numpy as np

from queue import Queue

from silero_vad import VADIterator, load_silero_vad
from sounddevice import InputStream

from tokenizers import Tokenizer

CHUNK_SIZE = 512            # silero VAD : 512 at 16kHz
LOOKBACK_CHUNKS = 5
MAX_LINE_LENGTH = 80
MAX_SPEECH_SECS = 15
MIN_REFRESH_SECS = 0.2

SUPPORTED_MODELS = ["moonshine/base", "moonshine/tiny"]

def load_tokenizer() -> Tokenizer:
    tokenizer_file = "tokenizer.json"
    return Tokenizer.from_file(str(tokenizer_file))

def _get_onnx_weights(model_name, precision="float"):
    from huggingface_hub import hf_hub_download

    if model_name not in ["tiny", "base"]:
        raise ValueError(f'Unknown model "{model_name}"')
    repo = "UsefulSensors/moonshine"
    subfolder = f"onnx/merged/{model_name}/{precision}"

    return (
        hf_hub_download(repo, f"{x}.onnx", subfolder=subfolder)
        for x in ("encoder_model", "decoder_model_merged")
    )


class MoonshineOnnxModel(object):
    def __init__(self, models_dir=None, model_name=None, model_precision="float"):
        import onnxruntime

        if models_dir is None:
            assert model_name is not None, (
                "model_name should be specified if models_dir is not"
            )
            encoder, decoder = self._load_weights_from_hf_hub(
                model_name, model_precision
            )
        else:
            encoder, decoder = [
                f"{models_dir}/{x}.onnx"
                for x in ("encoder_model", "decoder_model_merged")
            ]
        self.encoder = onnxruntime.InferenceSession(encoder)
        self.decoder = onnxruntime.InferenceSession(decoder)

        if "tiny" in model_name:
            self.num_layers = 6
            self.num_key_value_heads = 8
            self.head_dim = 36
        elif "base" in model_name:
            self.num_layers = 8
            self.num_key_value_heads = 8
            self.head_dim = 52
        else:
            raise ValueError(f'Unknown model "{model_name}"')

        self.decoder_start_token_id = 1
        self.eos_token_id = 2

    def _load_weights_from_hf_hub(self, model_name, model_precision):
        model_name = model_name.split("/")[-1]
        return _get_onnx_weights(model_name, model_precision)

    def generate(self, audio, max_len=None):
        "audio has to be a numpy array of shape [1, num_audio_samples]"
        if max_len is None:
            max_len = int((audio.shape[-1] / 16_000) * 6)

        import numpy as np

        last_hidden_state = self.encoder.run(None, dict(input_values=audio))[0]

        past_key_values = {
            f"past_key_values.{i}.{a}.{b}": np.zeros(
                (0, self.num_key_value_heads, 1, self.head_dim), dtype=np.float32
            )
            for i in range(self.num_layers)
            for a in ("decoder", "encoder")
            for b in ("key", "value")
        }

        tokens = [self.decoder_start_token_id]
        input_ids = [tokens]
        for i in range(max_len):
            use_cache_branch = i > 0
            decoder_inputs = dict(
                input_ids=input_ids,
                encoder_hidden_states=last_hidden_state,
                use_cache_branch=[use_cache_branch],
                **past_key_values,
            )
            logits, *present_key_values = self.decoder.run(None, decoder_inputs)
            next_token = logits[0, -1].argmax().item()
            tokens.append(next_token)
            if next_token == self.eos_token_id:
                break

            input_ids = [[next_token]]
            for k, v in zip(past_key_values.keys(), present_key_values):
                if not use_cache_branch or "decoder" in k:
                    past_key_values[k] = v

        return [tokens]
    
def set_cache_env(models_dir: str):
    os.makedirs(models_dir, exist_ok=True)
    os.environ.setdefault("HF_HOME", models_dir)  
    os.environ.setdefault("TORCH_HOME", models_dir)
    os.environ.setdefault("XDG_HOME", models_dir)
    os.environ.setdefault("SILERO", models_dir)

def right_justified_line(text: str, cache, width=MAX_LINE_LENGTH):
    if len(text) < width:
        for caption in cache[::-1]:
            text = caption + " " + text
            if len(text) > width:
                break
    if len(text) > width:
        text = text[-width:]
    else:
        text = " " * (width - len(text)) + text
    return text

class Model:
    def __init__(self, model_name: str):
        self.model = MoonshineOnnxModel(model_name=model_name)
        self.rate = 16000
        self.tokenizer = load_tokenizer()

        self.inference_secs = 0.0
        self.number_inferences = 0
        self.speech_secs = 0.0

        # warmup: 1s of zeros
        _ = self(np.zeros(int(self.rate), dtype=np.float32))

    def __call__(self, speech: np.ndarray) -> str:
        self.number_inferences += 1
        self.speech_secs += len(speech) / self.rate
        start = time.time()
        tokens = self.model.generate(speech[np.newaxis, :].astype(np.float32))
        text = self.tokenizer.decode_batch(tokens)[0]
        self.inference_secs += time.time() - start
        return text

class Transcribe:
    def __init__(self, model_name: str):
        self.model_name = model_name

        self.model = None
        self.rate = 16000
        self.vad_iterator = None
        self.queue = Queue()
        self.caption_cache = []
        self.stream = None
        self._running = False

    def _input_callback(self, data, frames, time_info, status):
        self.queue.put((data.copy().flatten(), status))

    def _soft_reset_vad(self):
        self.vad_iterator.triggered = False
        self.vad_iterator.temp_end = 0
        self.vad_iterator.current_sample = 0

    def _end_recording(self, speech: np.ndarray, do_print=True):
        text = self.model(speech)
        if do_print and self.print_transcription:
            line = right_justified_line(text, self.caption_cache)
            print("\r" + (" " * MAX_LINE_LENGTH) + "\r" + line, end="", flush=True)
        self.caption_cache.append(text)
        speech *= 0.0

    def warmup(self):
        if self.model is None:
            print(f"[stt] Loading model '{self.model_name}' (ONNX)...", flush=True)
            self.model = Model(self.model_name, rate=self.rate)

        if self.vad_iterator is None:
            vad_model = load_silero_vad(onnx=True)
            self.vad_iterator = VADIterator(
                model=vad_model,
                sampling_rate=self.rate,
                threshold=0.5,
                min_silence_duration_ms=300)

        if self.stream is None:
            self.stream = InputStream(
                samplerate=self.rate,
                channels=1,
                blocksize=CHUNK_SIZE,
                dtype=np.float32,
                callback=self._input_callback)

    def start(self):
        if self.stream is None:
            self.warmup()
        self._running = True
        self.stream.start()

        lookback_size = LOOKBACK_CHUNKS * CHUNK_SIZE
        speech = np.empty(0, dtype=np.float32)
        recording = False
        start_time = None

        try:
            with self.stream:
                while self._running:
                    chunk, status = self.queue.get()
                    if status:
                        print(status, flush=True)

                    speech = np.concatenate((speech, chunk))
                    if not recording:
                        speech = speech[-lookback_size:]

                    speech_dict = self.vad_iterator(chunk)
                    if speech_dict:
                        if "start" in speech_dict and not recording:
                            recording = True
                            start_time = time.time()

                        if "end" in speech_dict and recording:
                            recording = False
                            self._end_recording(speech)
                    elif recording:
                        if (len(speech) / self.rate) > MAX_SPEECH_SECS:
                            recording = False
                            self._end_recording(speech)
                            self._soft_reset_vad()

                        if (time.time() - start_time) > MIN_REFRESH_SECS:
                            text = self.model(speech)
                            line = right_justified_line(text, self.caption_cache)
                            print("\r" + (" " * MAX_LINE_LENGTH) + "\r" + line, end="", flush=True)
                            start_time = time.time()
        except KeyboardInterrupt:
            self.stop()

    def stop(self):
        self._running = False
        if self.stream:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
        print("[stt] Done.", flush=True)

def main():
    set_cache_env("/models")

    svc = Transcribe(model_name="moonshine/base")

    def _sigterm(sig, frame):
        svc.stop()
        sys.exit(0)
    signal.signal(signal.SIGTERM, _sigterm)
    signal.signal(signal.SIGINT, _sigterm)

    svc.warmup()
    svc.start()

if __name__ == "__main__":
    main()
