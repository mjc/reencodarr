#!/usr/bin/env zsh

lan_ip=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')

iex --name client@${lan_ip} --cookie reencodarr -S mix