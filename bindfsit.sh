#!/bin/bash

#binds the fs mounted on $real_mountpoint to $bind_mountpoint and when $real_mountpoint hangs, executes $recover_cmd and rebinds.
#if mount_cmd is not empty it will be executed when script starts.

#$1 is the configuration file, sourced by me with (eg):
	#mount_timeout=5 #seconds
    #check_every=10 #seconds
    #timeout_after=40 #seconds
    #restart_after=5 #seconds
    #real_mountpoint=/mnt/.bindfs/.myshare1
    #bind_mountpoint=/mnt/binfs/myshare1
    #mount_cmd="mount.cifs //pi/all $real_mountpoint -o rsize=131072,wsize=131072
    #user=koko # Makes all files owned by the specified user.
               # Also causes chown on the mounted filesystem to always fail.
    #SET_DEBUG=0|1 #Print verbose informations

## cat /usr/lib/systemd/system/bindfsit\@.service 
#[Unit]
#Description=Binds filesystems and recovers from hangs using config %I
#[Service]
#Type=simple
#Config files live in /etc/bindfsit/
#ExecStart=/usr/bin/bindfsit.sh /etc/bindfsit/"%I"
#[Install]
#WantedBy=default.target


#Set defaults before sourcing configuration file:
    mount_timeout=5
    mount_max_tries=5
	mount_retry_after=10
    check_every=10
    timeout_after=40
    restart_after=30
    real_mountpoint=/mnt/.bindfs/"$myownhost"
    bind_mountpoint=/mnt/bindfs/"$myownhost"
    recover_cmd=""
    SET_DEBUG=0

#Read configuration file and override defaults:
    source "$1" || exit 1

function debug {
	[ "$SET_DEBUG" = "1" ] && echo "[DD] $1"
}

function force_umount {
    echo [..] Cleaning...
    #The only open handle opened on the cifs share should be the bindfs one.
    echo [..] kill bindfs
    kill -9 $bindfs_pid
    try=0
	while true ; do
        let try=try+1
	    echo [..] forcing umounting bindfs on "$bind_mountpoint, try: $try"
        umount -f "$bind_mountpoint"
        if ! grep " $bind_mountpoint " /proc/self/mounts &>/dev/null ; then break ;fi
            #else...
        echo [EE] "$bind_mountpoint is still mounted."
        if [ $try = 6 ] ; then
            echo "[EE] Couldn't (force) umount $bind_mountpoint"
            echo "[..] Lazying umounting bindfs on $bind_mountpoint"
            mount -l "$bind_mountpoint"
            break
        fi
        sleep 1
    done
    echo "[..] Lazying umounting $real_mountpoint"
    umount -l "$real_mountpoint"
    echo "[OK] Done."
    echo "[OK] Done cleaning."
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
    try=1
	#mount real mountpoint, wait at most 5+1 seconds every time it tries
    if [ ! -z "$mount_cmd" ] ; then
    echo "Trying to mount $real_mountpoint"
        while ! sh -c "timeout -k 1 $mount_timeout $mount_cmd" ; do
            if [ "$try" = "$mount_max_tries" ] ; then
                echo "[EE] Couldn't mount $real_mountpoint in $try tries, giving up :("
                exit
            fi
            echo "($try/$mount_max_tries) Mount failed, sleeping $mount_retry_after seconds to retry"
            sleep $mount_retry_after ;
            let try=try+1
            debug "($try/$mount_max_tries) Retrying to mount..."
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
echo real_mountpoint="$real_mountpoint"
echo bind_mountpoint="$bind_mountpoint"
echo user="$user"
echo mount_cmd="$mount_cmd"
echo mount_timeout="$mount_timeout"
echo mount_max_tries="$mount_max_tries"
echo mount_retry_after="$mount_retry_after"
echo timeout_after="$timeout_after"
echo check_every="$check_every"
echo restart_after="$restart_after"
echo recover_cmd="$recover_cmd"

#Make mountpoints:
debug "Making mountpoints"
if [ ! -d "$real_mountpoint" ] ; then mkdir -p "$real_mountpoint"  || exit 1 ; fi
if [ ! -d "$bind_mountpoint" ] ; then mkdir -p "$bind_mountpoint"  || exit 1 ; fi

while true ; do
    mount_real
    mount_bind

    echo [OK] Start Main check cycle, whill check every $check_every seconds...
    while true ; do

        debug "check if $real_mountpoint is mounted"
        if ! grep " $real_mountpoint " /proc/self/mounts &>/dev/null ; then
            echo "$real_mountpoint does not seem to be mounted anymore."
	    break
        fi

        #fixme: can we use stat and not ls here?

	    debug "check if $real_mountpoint is answering"
        if ! timeout -k 1 $timeout_after ls "$real_mountpoint" &>/dev/null ; then
            echo "no answer from $real_mountpoint"
            break
                else
            debug "Share is alive on $real_mountpoint !"
        fi
        debug "sleeping $check_every"
        sleep $mount_retry_after
    done

    force_umount
    execute_recover_cmd
    echo [..] Waiting $restart_after seconds: $(date)
    sleep $restart_after
done

