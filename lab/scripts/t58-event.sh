#!/bin/sh
# tsswitch --event-command for T58: append `switch_<from>_<to> <unix seconds>` to the events file.
#
#   tsswitch --event-command "sh t58-event.sh <events.txt>" ...
#
# tsswitch appends the event's name ("newinput"), the input index before it and the one after.
printf 'switch_%s_%s %s\n' "$3" "$4" "$(perl -MTime::HiRes=time -e 'printf "%.6f", time')" >>"$1"
