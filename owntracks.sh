#!/usr/bin/env bash

mosquitto_sub -h elephant.vpn.freumh.org -p 1883 -t 'owntracks/#' |\
	jq --unbuffered -r 'select(._type == "location") | "\(.lat) \(.lon) \(.acc // 50)"' |\
	while read lat lon acc; do 
		# Set zoom based on accuracy: smaller acc = more precise = higher zoom
		if [ "$acc" -le 10 ]; then zoom=18  # building level
		elif [ "$acc" -le 25 ]; then zoom=17  # street level
		elif [ "$acc" -le 50 ]; then zoom=16  # major street level
		elif [ "$acc" -le 100 ]; then zoom=15 # neighborhood level
		elif [ "$acc" -le 500 ]; then zoom=14 # suburb level
		else zoom=12; fi  # city level
		
		curl -s "https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&zoom=$zoom&format=json" | jq
	done