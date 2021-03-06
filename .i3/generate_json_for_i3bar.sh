#!/usr/bin/env bash

# generate-text-for-i3bar.sh
# A replacement for i3status written in bash.

# Shebang here is just for you to check the JSON output for syntax errors,
#   not for running as executable in your i3 config,
#   where it must be _sourced_ from.

[ "${ENV_DEBUG/*g*/}" ] || exec 2>/tmp/envlogs/gentext4i3bar

# Colors for output
red='#ee1010'
yellow='#edd400'
green='#8ae234'
white='#ffffff'
orange='#e07a1f'
brown='#b16161'
blue='#729fcf'
timeout_step=0 # counts seconds till timeout_max
timeout_max=30 # the actual timeout is one second; timeout_max introduces
               # a period functions may rely on; functions have their own
               # local timeouts, “wait_time” variable.
separator_char='·'  # U+00B7 https://en.wikipedia.org/wiki/Interpunct

# module settings
active_window_name_max_length=50

# Decrypt Gmail authentication data
eval `gpg -qd ~/.env/private_data.sh.gpg 2>/dev/null \
      | grep -E '^GMAIL_(USERNAME|PASSWORD)'`

# Tabulation and spaces in output of the script are just to have a nice view
#   while testing this script in a terminal and are not neccesary.

# 1. Let’s call each element of the status bar ‘a block’.
# 2. Then each block is consisted of a variable which will contain related JSON
#    stuff and a function generating that JSON. Functions are named after
#    the variables, but have ‘get_’ prefix.
# 3. The ‘blocks’ array defines the list of blocks which will be used to compile
#    the bar string; index number defines the priority of each block, i.e. will
#    it appear first and on the left (lower index) or last and on the right
#    (highest index).
# 4. What is actually shown on the bar is defined by the $bar variable, which
#    contains a string of _variable names_, in other words, block names. This
#    string evaluates at runtime each time after all functions in func_list
#    are done.
blocks=(
	# [0]=test [1]=separator
	[10]=active_window_name

	# indicators block
	[20]=mpd_state
	[30]=speakers_state
	[31]=mic_state
	[40]=internet_status
	[50]=gmail

	[59]=cond_separator_1 # conditional separator
	[60]=nice_date
)

case $HOSTNAME in
	fanetbook)
		blocks[54]=xkb_layout
		blocks[59]=battery_status
		;;
	home)
		blocks[15]=free_space
		blocks[16]=separator
		blocks[55]=schedule
		;;
esac

unset func_list
# $bar is to be eval’ed to output
bar='${comma:-}\n\t[' # Since comma isn’t set for the first time, its line will be empty
for block in ${blocks[@]}; do
	func_list+=" get_$block"
	bar+='\n\t${'$block':-}'
done
bar+="\n\t]"


# Some functions may generate empty line if no indicator needed.

# DESCRIPTION:
#     Block for testing purposes.
get_test() {
	# https://developer.gnome.org/pango/stable/PangoMarkupFormat.html
	test='{ "full_text": "<span foreground=\"blue\" bgcolor=\"#efefef\" size=\"x-large\">Blue text</span> is <i>cool</i>!",
\t  "align": "right",
\t  "markup": "pango",
\t  "separator": false },'
}

# DESCRIPTION:
#     The problem with i3bar separator is, if a separator symbol is set
#       in the bar section of i3 config, it WILL take space on the bar,
#       even if "separator":"false" is passed through json.
get_separator() {
	separator='{ "full_text": "'$separator_char'",
\t  "separator": false },'
}

# DESCRIPTION:
#     This separator is conditional and appears only when there is at least
#       one indicator shown (no indicators may be present and that’s a taihen)
#     The logic is each block of the same group sets variable like
#       set_cond_separator_N, where N is common for all blocks within a group.
#       Function as this checks that variable and prints conditional separator
get_cond_separator_1() {
	unset cond_separator_1
	[ -v set_cond_separator_1 ] \
		&& cond_separator_1='{ "full_text": "'$separator_char'",
\t  "separator": false },'
}

# NOTE:
#     Despite the fact it may seem useless to have, because all the important
#       info you should be able to output in the window itself (also window
#       titles while stacked/tabbed), and on small screens there may be
#       not enough space for the title, but it’s here
#         - just for it to be if it accidentally become needed;
#         - if window lags and its output is grey screen or copy of what was
#           on the previous workspace, this window title is the only way you
#           can tell what actually this window is and where is belongs to.
get_active_window_name() {
	id=`xprop -root | sed -nr 's/^_NET_ACTIVE_WINDOW.*# (.*)$/\1/p'`
	local title=`xprop -id "$id" | sed -nr 's/\\\//g;s/^WM_NAME[^"]+"([^"]+)".*/\1/p'` \
		u_open u_close
	[ ${#title} -gt $active_window_name_max_length ] && {
		## sed is expensive
		title=`echo "$title" | sed -r "s/^(.{1,$active_window_name_max_length})\b.*/\1…/"`
		## bash is not, but treats words with less care
		# title=${title:0:$max_length}
	}
	# to underline window titles that have spaces
	# [ "${title//* */}" ] || { u_open='<u>'; u_close='</u>'; }
	active_window_name='{ "full_text": "'"$u_open$title$u_close${title:+ $separator_char}"'",
\t  "align": "right",
\t  "markup": "pango",
\t  "separator": false },'
}

get_xkb_layout() {
	# When compiling my own xkb map via xkbcomp, I used the layout I made
	#   with setxkbmap where Scroll Lock indicator was used to indicate
	#   the current layout. But there’s no indicator on the tiny keyboard
	#   I’ve bought recently, so this function is to substitute this lack.
	#   Oh there was also a specific tool to print the current layout,
	#   https://github.com/ierton/xkb-switch I dunno how reliable it is,
	#   and since it’s not in repositories, I rather use xset.
	local scroll_lock=`xset -q | sed -nr 's/.*Scroll Lock:\s+(\S+)\s*$/\1/p'`
	[ "$scroll_lock" = on ] \
		&& local scroll_lock=RUS \
		|| local scroll_lock=ENG
#\t  "color": "#00ff00",
	xkb_layout='{ "full_text": "'"$scroll_lock"'",
\t  "align": "right",
\t  "separator": false },'
	set_cond_separaor_1=t
}

get_free_space() {
	local wait_time=10 color_tag inner_separator
	[ $timeout_step -eq 0 -o $((timeout_step % wait_time)) -eq 0 ] && {
		mountpoints='/home / /usr'
		yellow_point='5'
		red_point='1'
		unset free_space
		for mountpoint in $mountpoints; do
		# We look for an existed mount point which is in use and not bound.
			sed -nr "s~^\S+\s+$mountpoint\s+\S+\s+(\S+)\s.*~\1~p" \
				/proc/mounts | grep -qv bind \
			&& local present_mpoints[${#present_mpoints[@]}]="$mountpoint"
		done
		[ -v present_mpoints ] && for ((i=0; i<${#present_mpoints[@]}; i++)); do
			[ $i -lt $((${#present_mpoints[@]}-1)) ] \
				&& local inner_separator=" $_not_used_until_they_fix_the_bug_separator_char " \
				|| unset inner_separator # This comma appears between blocks
			                              #   showing mountpoints.
			read total free <<< `df -BG -P "${present_mpoints[$i]}" |\
			  sed -rn '$ s/^\S+\s+([0-9]+)G\s+\S+\s+([0-9]+)G.*$/\1\n\2/p'`
			unset color_tag
			if [ $free -le $red_point ]; then
				color_tag='<span fgcolor=\"'$red'\">'
			elif [ $free -le $yellow_point ]; then
				color_tag='<span fgcolor=\"'$yellow'\">'
			fi
			# extra space for the last iteration
			# $separator_char isn’t used here in favour of {separator} block
			#   because of the middle line shifted by the subscript tag.
			[ $((i+1)) -eq ${#present_mpoints[@]} ] && inner_separator+=' '
			free_space="${free_space:-}${inner_comma:-}
\t{ \"full_text\": \"${color_tag:-}${present_mpoints[$i]}:$free${color_tag:+</span>}/<sub>$total</sub>$inner_separator\",
\t  \"separator\":false,
\t  \"separator_block_width\":0,
\t  \"markup\": \"pango\" }"

			local inner_comma=',' # This comma is a part of json and divides
			                      #   {blocks} of code.
		done
		[ "$free_space" ] && free_space="$free_space," # buuug >_< $inner_comma isn’t appended to the last block
	}
}


get_mpd_state() {
	unset mpd_caught_playing mpd_state
	mpc |& sed '2s/playing//;T;Q1' &>/dev/null || {
		mpd_caught_playing=t # this uses in get_gmail
		mpd_state='{ "full_text": "♬",\n\t  "separator": false },'
		set_cond_separator_1=t
	}
}

get_speakers_state() {
	unset speakers_state
	amixer get 'Master',0 |& sed '$s/on]$/&/;T;Q1' &>/dev/null && {
		speakers_state="{ \"full_text\": \"⊀\",
\t  \"color\": \"$red\",
\t  \"separator\": false },"
		set_cond_separaor_1=t
	}
}

get_mic_state() {
	unset mic_state
	amixer get 'Capture',0 |& sed '$s/on]$/&/;T;Q1' &>/dev/null && {
		mic_state="{ \"full_text\": \"⍉\",
\t  \"color\": \"$red\",
\t  \"separator\": false },"
		set_cond_separaor_1=t
	}
}

get_battery_status() {
	local wait_time=30
	[ $timeout_step -eq 0 -o $((timeout_step % wait_time)) -eq 0 ] && {
		unset battery_status journal debug blocks offset next_block \
		      bat_time_left bat_ejected
		[ -e /sys/class/power_supply/ADP1/online ] && {
			# We have adapter, and probably, battery.
			if [ -e /sys/class/power_supply/BAT1/status ]; then
				# Yes, battery is present too.
				pushd /sys/class/power_supply &>/dev/null
				[ -v battery_initial_data_prepared ] || {
					# Maximum charge available after the last calibration
					charge_full=$(< BAT1/charge_full)
					# Maximum charge as it was designed
					charge_full_design=$(< BAT1/charge_full_design)
					# When charging, this shows how much
					charge_now=$(< BAT1/charge_now)
					# Strange values, used only for journal
					## current_now=$(< BAT1/current_now)

					steps_per_block=' ░▒▓█'
					blocks_count=5
					levels_count=$(( ${#steps_per_block} * $blocks_count ))
					total_hours_by_design="6"
					battery_initial_data_prepared=t
				}
				# When charging, this shows how much
				charge_now=$(< BAT1/charge_now)
				# Battery status by kernel
				bat_status=$(< BAT1/status)
				# Is external power supply plugged?
				adp_online=$(< ADP1/online)
				popd &>/dev/null

				battery_lifetime=`echo "scale=2;
                                  $total_hours_by_design*$charge_now\
				                  /$charge_full_design" | bc`
				bat_lt_hours=${battery_lifetime%.*}
				[ ${#bat_lt_hours} -ne 0 ] && \
					bat_lt_hours="${bat_lt_hours}h " || unset bat_lt_hours
				bat_lt_minutes=`echo "scale=0; ${battery_lifetime#*.}*3/5" | bc`
				[ ${#bat_lt_minutes} -ne 0 ] && \
					bat_lt_minutes="${bat_lt_minutes}m"
				bat_time_left=" ${bat_lt_hours:-}${bat_lt_minutes:-}"
# W!
# Write a journal of battery charge level till it’s completely discharged.
# Be sure _the filesystem_ you save journal on _is protected_ from power loss,
#   e.g. has "data=journal,barrier=1" among mount opts for ext3/4, otherwise
#   all discharging will be in vain.
				# journal=/battery_journal.csv
				level=$(( $charge_now * $levels_count / $charge_full ))
				full_blocks=$(( $level / $blocks_count ))
				[ $full_blocks -lt $blocks_count ] && {
					if [ $level -eq 0 ]; then
						offset=$level
					else
						offset=$(( $level - $full_blocks * $blocks_count - 1 ))
					fi
					next_block=${steps_per_block:$offset:1}
				}

				for ((i=0; i<$full_blocks; i++)); do
					blocks="$blocks${steps_per_block:4:1}"
				done
				[ -v next_block ] && blocks="$blocks$next_block"
				while [ ${#blocks} -lt $blocks_count ]; do
					blocks="$blocks${steps_per_block:0:1}"
				done

				if [ $adp_online -eq 1 ]; then
					color=$green
				elif [ $level -ge 5 ]; then
					color=$white
				elif [ $level -gt 1 ]; then
					color=$orange
				else
					# Battery is about to be discharged completely → 0
					# (but still can work for 30 min in idle for me)
					color=$red
					# Throw a message about shutdown and try to perform it.
					$(Xdialog --timeout 5 \
						--ok-label Shutdown --cancel-label 'NO, WAIT!' \
						--yesno 'Battery level is low.\nIt’s time to shutdown soon.' 370x100)
					[ $charge_now -eq 0 -a $? -eq 0 ] && {
						shutdown &>/dev/null || { # ~/bin/shutdown
							Xdialog --msgbox 'Shutdown returned with an error.\nYou have to do it manually!' 330x100
							# If the script cannot call shutdown itself,
							#   it must at least try to save the energy
							#   going to sleep for 20 minutes (by that time
							#   the battery will be probably exhausted).
							sleep 1200
						}
					}
				fi
				# [ -v journal ] && \
				# echo "`date +%s`;$charge_now;$current_now;$level" >> $journal
			else
				blocks='EJECTED'
				color=$red
			fi
		} || {
			blocks='NO POWER_SUPPLY CLASS FOUND'
			color=$red
		}
		battery_status="{ \"full_text\": \"┫$blocks┣${bat_time_left:-}\",
\t  \"color\":\"$color\",
\t  \"separator\":false },"
	}
	set_cond_separaor_1=t
}

get_internet_status() {
	local wait_time=5
	[ $timeout_step -eq 0 -o $((timeout_step % wait_time)) -eq 0 ] && {
		unset has_internets
		[ -p /dev/fd/$pingout ] && {
			grep -q ' 0% packet loss' </dev/fd/$pingout \
				&& has_internets=t && {
				internet_status='{ "full_text": "",
\t  "separator":false },'
				# set_cond_separaor_1=t
			}||{
				internet_status='{ "full_text": "∿",
\t  "color": "'$red'",
\t  "separator":false },'
				set_cond_separaor_1=t
			}
			exec {pingout}<&-
		}
		[ -v COPROC ] || {
			# wait_time can be here 2×, 3× timeouts or more.
			coproc ping -W $wait_time -q -n -c1 8.8.4.4
			# <& duplicates input file descriptors,
			# >& duplicates output file descriptors, They both work here.
			# {braces} are important.
			exec {pingout}<&${COPROC[0]}
		}
	}
}

get_gmail() {
	local wait_time=5
	[ $timeout_step -eq 0 -o $((timeout_step % wait_time)) -eq 0 ] && {
		unset gmail
		if [ -v has_internets ]; then
			gmail_server_reply=`curl --connect-timeout $wait_time \
			-su $GMAIL_USERNAME:$GMAIL_PASSWORD \
		    https://mail.google.com/mail/feed/atom 2>/dev/null`
			[ "$gmail_server_reply" ] || {
				# Unable to connect to mail.google.com
				gmail='{ "full_text": "U✉",
\t  "color": "'$orange'",
\t  "separator":false },'
				set_cond_separaor_1=t
				return 1
			}
			sed -r 's~^<H2>Error [0-9]{3}</H2>$~&~;T;Q1' \
				&>/dev/null <<<"$gmail_server_reply" || {
				# Server reported invalid user data or other fault.
				gmail='{ "full_text": "E✉",
\t  "color": "'$red'",
\t  "separator":false },'
				set_cond_separaor_1=t
				return 1
			}
			letters_unread=`sed -nr 's/.*<fullcount>([0-9]+)<.*/\1/p' \
			                <<<"$gmail_server_reply"`
			[ "$letters_unread" -gt 0 ] && {
				# Yay, a new letter!
				gmail='{ "full_text": "'$letters_unread'",
\t  "color": "'$green'",
\t  "separator":false,
\t  "separator_block_width":0 },
\t{ "full_text": "✉",
\t  "color": "'$green'",
\t  "separator":false },'
				set_cond_separaor_1=t
			}
			[ "$letters_unread" -gt ${old_letters_unread:-0} ] && {
				[ -v mpd_caught_playing ] && mpc pause >/dev/null
				aplay ~/.env/Tutturuu_v2.wav           >/dev/null
				[ -v mpd_caught_playing ] && mpc play  >/dev/null
			}
			old_letters_unread=$letters_unread
		fi
	}
}

get_schedule() {
	local wait_time=30 dayofweek dayofmonth hour minutes
	[ $timeout_step -eq 0 -o $((timeout_step % wait_time)) -eq 0 ] && {
		unset schedule
		read dayofweek dayofmonth hour minutes <<<$(date "+%A %-d %-H %-M")
		# All the indicators shut down either by themselves after timeout or
		#   with aliases from ~/bashrc/home.sh. See ‘wtr’, ‘snt’, ‘okiru’.
		# Watering plants
		case $dayofweek in
			# If ~/watered hasn’t been `touch`ed within 1/2/3 days…
			Понедельник|Четверг) # Monday and Thursday—days for watering plants
				[ "`find $HOME/ -maxdepth 1 -name watered -mtime -1 2>/dev/null`" ] \
					|| schedule='{ "full_text": "✼",
\t  "color": "'$green'",
\t  "separator": false },'
				;;
			Вторник|Пятница) # Tuesday and Friday show that I forgot to do that yesterday
				[ "`find ~/ -maxdepth 1 -name watered -mtime -2 2>/dev/null`" ] \
					|| schedule='{ "full_text": "✼",
\t  "color": "'$yellow'",
\t  "separator": false },'
				;;
			Среда|Суббота) # two days delay, やべえ〜
				[ "`find ~/ -maxdepth 1 -name watered -mtime -3 2>/dev/null`" ] \
					|| schedule='{ "full_text": "✼",
\t  "color": "'$brown'",
\t  "separator": false },'
				;;
		esac
		# Sending water counters data
		[ $dayofmonth -ge 15 ] \
			&& [ -z "`find ~/ -maxdepth 1 -name sent -mtime -$((dayofmonth-14)) 2>/dev/null`" ] \
			&& schedule="${schedule:+${schedule}\n}"'{ "full_text": "♒",
\t  "color": "'$blue'",
\t  "separator": false },'
		# Waking a certain someone
		case $dayofweek in
			Понедельник|Вторник|Среда|Четверг|Пятница) # Mon–Fri
				[ $hour -eq 6 -a $minutes -ge 5 ] && [ -e /tmp/okiru ] \
					&& schedule="${schedule:+${schedule}\n}"'{ "full_text": "起きる",
\t  "color": "'$green'",
\t  "separator": false },'
				;;
		esac
	}
	[ "$schedule" ] && set_cond_separator_1=t
}

get_nice_date() {
	# This is to fix declensional endings of months’ names in russian locale.
	local wait_time=10
	[ $timeout_step -eq 0 -o $((timeout_step % wait_time)) -eq 0 ] && {
		# Why %b is “июня”, but “июл”? >_>
		# nice_date=`date +'%A, %-d %b %-H:%M'`
		nice_date=`date +'%A, %-d =%-m= %-H:%M' \
	         | sed 's/=1=/января/;   s/=2=/февраля/;
	                s/=3=/марта/;    s/=4=/апреля/;
	                s/=5=/мая/;      s/=6=/июня/;
	                s/=7=/июля/;     s/=8=/августа/;
	                s/=9=/сентября/; s/=10=/октября/;
	                s/=11=/ноября/;  s/=12=/декабря/'`
		nice_date='{ "full_text": "'$nice_date'",
\t "markup": "pango",
\t "urgent": "true" }'
	}
}

# http://i3wm.org/docs/i3bar-protocol.html
echo '{"version":1}[' && while true; do
	for func in $func_list; do
		$func
	done
	eval echo -e \"${bar//\\/\\\\}\" || exit 3
	comma=','
	unset ${!set_cond_separator_*}
	sleep 1;
	[ $((++timeout_step)) -gt $timeout_max ] && timeout_step=1
done
