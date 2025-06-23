#!/usr/bin/env bash

# syntax: client.sh client_name@hostname server_name@hostname
client_name=$1
server_name=$2
 mix reencodarr.worker --name $client_name --connect-to $server_name --capabilities crf_search,encode --cookie reencodarr