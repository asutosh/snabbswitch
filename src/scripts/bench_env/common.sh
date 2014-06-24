
# run QEMU with args
# - NUMA node
# - kernel ARGS
# - IMG name
# - MAC address
# - PORT for telnet serial
# - NETDEV the netdev line
run_qemu () {
    if [ "$#" -ne 6 ]; then
        print "wrong run_qemu args\n"
        exit 1
    fi
    NUMANODE=$1
    ARGS=$2
    IMG=$3
    MAC=$4
    TELNETPORT=$5
    NETDEV=$6

    MEM="-m $GUEST_MEM -numa node,memdev=mem -object memory-backend-file,id=mem,size=${GUEST_MEM}M,mem-path=$HUGETLBFS,share=on"
    NET="$NETDEV -device virtio-net-pci,netdev=net0,mac=$MAC"

    # Execute QEMU on the designated node
    numactl --cpunodebind=$NUMANODE --membind=$NUMANODE \
        $QEMU \
            -kernel $KERNEL -append "$ARGS" \
            $MEM $NET \
            -M pc -smp 1 -cpu host --enable-kvm \
            -serial telnet:localhost:$TELNETPORT,server,nowait \
            -drive if=virtio,file=$IMG \
            -nographic > /dev/null 2>&1 &
    QEMUPIDS="$QEMUPIDS $!"
}

# run QEMU with args
# - NUMA node
# - kernel ARGS
# - IMG name
# - MAC address
# - PORT for telnet serial
# - vhost-user SOCKET
run_qemu_vhost_user () {
    if [ "$#" -ne 6 ]; then
        print "wrong run_qemu_vhost_user args\n"
        exit 1
    fi
    SOCKET=$6
    NETDEV="-netdev type=vhost-user,id=net0,chardev=char0 -chardev socket,id=char0,path=$SOCKET,server"
    run_qemu "$1" "$2" "$3" "$4" "$5" "$NETDEV"
}

# run QEMU with args
# - NUMA node
# - kernel ARGS
# - IMG name
# - MAC address
# - PORT for telnet serial
# - tap name
# Execute QEMU, remove redirection for verbosity
run_qemu_tap () {
    if [ "$#" -ne 6 ]; then
        print "wrong run_qemu_vhost_user args\n"
        exit 1
    fi
    TAP=$6
    NETDEV="-netdev type=tap,id=net0,script=no,downscript=no,vhost=on,ifname=$TAP"
    run_qemu "$1" "$2" "$3" "$4" "$5" "$NETDEV"
}

import_env () {
    # Check if configuration file is present on etc directory
    ENV_FILE="$1/bench_conf.sh"
    [ -f $ENV_FILE ] && . $ENV_FILE || \
    {
        printf "Configuration file $ENV_FILE not found.\n" && \
        return 1
    }

    printf "Sourced $ENV_FILE\n"
    printf "\n------\n"
    cat $ENV_FILE
    printf "\n------\n"
    return 0
}

wait_qemus () {
    for pid in "$QEMUPIDS"; do
        wait $pid
    done
}

wait_pid () {
    for pid in "$@"; do
        #wait $pid
	sleep 1
    done
}

kill_pid () {
    for pid in "$@"; do
        kill -9 $pid > /dev/null 2>&1 || true
    done
}

rm_file () {
    for f in "$@"; do
        if [ -e $f ]; then
            rm -f $f
        fi
    done
}

on_exit () {
    # cleanup on exit
    printf "Waiting QEMU processes to terminate...\n"
    wait_pid $QEMUPIDS

    # Kill qemu and snabbswitch instances and clean left over socket files
    kill_pid $QEMUPIDS $SNABB_PID0 $SNABB_PID1
    rm_file $NFV_SOCKET0 $NFV_SOCKET1
    printf "Finished.\n"
}

detect_snabb () {
    for f in "$@"; do
        if [ -x "$f/snabb" ]; then
            export SNABB=$f/snabb
        fi
    done
}

# Check if the script was executed as root
if [ ! $(id -u) = 0 ]; then
    printf "This script must be run as root.\n"
    exit 1
fi

#save overridable values
_SNABB=$SNABB

# import the global config
import_env "/etc" || ( printf "No /etc/bench_conf.sh found\n" && exit 1 )
# overrirde from home folder
import_env "$HOME"

# patch imported variables
if [ -n "$_SNABB" ]; then
    export SNABB=$_SNABB
else
    # detect snabb in the current path if run from inside the snabb tree
    # and not overried on the command line
    detect_snabb ./ ./src $(dirname $0)/../../
fi

# detect designs
printf "SNABB=$SNABB\n"
SNABB_PATH=$(dirname $SNABB)
if [ -f $SNABB_PATH/designs/nfv/nfv ]; then
    export NFV=$SNABB_PATH/designs/nfv/nfv
else
    printf "NFV design not found\n"
    exit 1
fi

if [ -f $SNABB_PATH/designs/loadgen/loadgen ]; then
    export LOADGEN=$SNABB_PATH/designs/loadgen/loadgen
else
    printf "LOADGEN design not found\n"
    exit 1
fi

# Check if the guest memory will fit in hugetlbfs
PAGES=`cat /proc/meminfo | grep HugePages_Free | awk  '{ print $2; }'`
PAGES=`expr $PAGES \* 2`

TOTAL_MEM=`expr $GUEST_MEM \* $GUESTS`

# setup a trap hook
trap on_exit EXIT HUP INT QUIT TERM

# lock the resources
do_lock () {
    printf "Locking $1\n"
    eval "exec $2>\"/var/run/bench$1.pid\""
    flock -n -x $2

	if [ $? != 0 ]; then
	    printf "can't get lock on $1"
	    exit 1
	fi
    echo $$ 1>&$2
}

do_lock $NFV_PCI0 8
do_lock $NFV_PCI1 9
