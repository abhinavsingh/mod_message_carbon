#!/bin/sh
mkdir -p ebin
erl -pa /lib/ejabberd/ebin -pz ebin -make