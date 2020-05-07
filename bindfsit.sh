#!/bin/bash

#binds the fs mounted on $real_mountpoint to $bind_mountpoint and when $real_mountpoint hangs, executes $recover_cmd and rebinds.
#if mount_cmd is not empty it will be executed when script starts.

#$1 is the configuration file, sourced by me with (eg):
    #check_every=10 #seconds
    #timeout_after=40 #seconds
    #restart_after=5 #seconds
    #real_mountpoint=/mnt/.bindfs/.myshare1
    #bind_mountpoint=/mnt/binfs/myshare1
    #mount_cmd="mount.cifs //pi/all $real_mountpoint -o rsize=131072,wsize=131072
    #user=koko # Makes all files owned by the specified user.
               # Also causes chown on the mounted filesystem to always fail.

source "$1" || exit 1

# It is handy to bind the whole autofs tree, i use it that way:

#koko@slimer# cat /etc/systemd/system/bindfs_autofs.service 
#[Unit]
#Description=Binds the autofs tree and recover from stalls
#
#[Service]
#Type=simple
#ExecStartPre=systemctl start autofs
#ExecStart=/home/koko/scripts/bindfs_it.sh /mnt/autofs.real /mnt/autofs "umount -l /mnt/autofs.real/*"
#
#[Install]
#WantedBy=default.target

function force_umount {
	echo [..] Cleaning...
	#The only open handle opened on the cifs share should be the bindfs one.
	echo [..] kill bindfs
	kill -9 $bindfs_pid
	echo [..] forcing umounting bindfs on "$bind_mountpoint"
	umount -f "$bind_mountpoint"
	echo [..] Lazying umounting "$real_mountpoint"
	umount -l "$real_mountpoint"
	echo [OK] Done.
	echo [OK] Done cleaning.
}

function execute_recover_cmd  {
    # execute recover command
    if [ ! -z "$recover_cmd" ] ; then
        echo [..] Execute: "$recover_cmd"
        sh -c "$recover_cmd"
    fi
}

function finish {
    echo exiting...
	force_umount
	trap exit INT TERM EXIT
	exit
}

function mount_real {
    echo "mounting $real_mountpoint"
    if [ ! -z "$mount_cmd" ] ; then
        while ! sh -c "$mount_cmd" ; do 
           sleep $restart_after ; 
        done
    fi
    echo "mounted $real_mountpoint"   
}

function mount_bind {
    echo [..] binding "$real_mountpoint" to "$bind_mountpoint"
    bindfs -u $user "$real_mountpoint" "$bind_mountpoint"
    #Getting the pid of bindfs is tricky.
    bindfs_pid=$(ps -eo pid,args|grep bindfs | grep " $real_mountpoint $bind_mountpoint" |grep -vi grep |awk '{print $1}')
    echo bindfs pid: $bindfs_pid
    echo [OK] mounted bind "$cifs_mountpoint" on "$bind_mountpoint", pid: "$bindfs_pid"
}



# MAIN ####################################

trap finish INT TERM EXIT

echo $(basename $0) config:
echo config file="$1"
echo check_every="$check_every"
echo timeout_after="$timeout_after"
echo restart_after="$restart_after"
echo real_mountpoint="$real_mountpoint"
echo bind_mountpoint="$bind_mountpoint"
echo mount_cmd="$mount_cmd"
echo recover_cmd="$recover_cmd"
echo user="$user"

#Make mountpoints:
if [ ! -d "$real_mountpoint" ] ; then mkdir -p "$real_mountpoint"  || exit 1 ; fi
if [ ! -d "$bind_mountpoint" ] ; then mkdir -p "$bind_mountpoint"  || exit 1 ; fi

while true ; do
    mount_real
    mount_bind

    echo [OK] Start Main check cycle, whill check every $check_every seconds...
    while true ; do

        #echo "check if $real_mountpoint is mounted"
        if ! grep " $real_mountpoint " /proc/self/mounts &>/dev/null ; then
            echo "$real_mountpoint does not seem to be mounted anymore."
	    break
        fi

        #fixme: can we use stat and not ls here?

	    #echo "check if $real_mountpoint is answering"
        if ! timeout -k 1 $timeout_after ls "$real_mountpoint" &>/dev/null ; then
            echo "no answer from $real_mountpoint"
            break
        fi
        #echo sleeping
        sleep $check_every
    done

    force_umount
    execute_recover_cmd
    echo [..] Waiting $restart_after seconds: $(date)
    sleep $restart_after
done

