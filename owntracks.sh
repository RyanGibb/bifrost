#!/usr/bin/env bash

mosquitto_sub -h elephant.vpn.freumh.org -p 1883 -t 'owntracks/#' |\
	jq --unbuffered -r 'select(._type == "location") | "\(.lat) \(.lon)"' |\
	while read lat lon; do curl -s "https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json" | jq; done