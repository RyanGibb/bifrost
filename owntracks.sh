#!/usr/bin/env bash

mosquitto_sub -h elephant.vpn.freumh.org -p 1883 -t 'owntracks/#' |\
	jq --unbuffered -r 'select(._type == "location") | "\(.lat) \(.lon) \((18 - (.acc // 50) / 50) | floor | if . > 18 then 18 elif . < 12 then 12 else . end)"' |\
	while read lat lon zoom; do 
		curl -s "https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&zoom=$zoom&format=json" | jq
	done