STT_REMOTE_HOST=pi@bifrost.freumh.org \
STT_REMOTE_PORT=2349 \
STT_SSH_KEY=$HOME/.ssh/id_ed25519_bifrost \
STT_REMOTE_STRICT=no \
STT_IMAGE=j0shm/stt-service:latest \
STT_CONTAINER=stt \
STT_RUN_ARGS="--device /dev/snd --group-add audio -v stt_models:/models -e MODEL_NAME=moonshine/base" \
STT_VERIFY=1 \
dune exec paper/engine.exe paper/william_gates_building.capnp paper/spawn_rule.capnp paper/stt_rule.capnp