#!/bin/bash
#
# Run select tests by setting ONLY, or as arguments to the script.
# Skip specific tests by setting EXCEPT.
#
# exit on error
set -e
set +o monitor

SRCDIR=$(dirname $0)
export PATH=$PWD/$SRCDIR:$SRCDIR:$PWD/$SRCDIR/utils:$PATH:/sbin:/usr/sbin

ONLY=${ONLY:-"$*"}
# bug number for skipped test:
# UPDATE THE COMMENT ABOVE WITH BUG NUMBERS WHEN CHANGING ALWAYS_EXCEPT!
# skip test cases failed before landing - Jinshan
ALWAYS_EXCEPT="$SANITY_HSM_EXCEPT 12a 12b 12n 13 24 30a 31a 34 35 36 52 58 59"
ALWAYS_EXCEPT="$ALWAYS_EXCEPT 110a 200 201 221 222a 223a 223b 225 226"

LUSTRE=${LUSTRE:-$(cd $(dirname $0)/..; echo $PWD)}

. $LUSTRE/tests/test-framework.sh
init_test_env $@
. ${CONFIG:=$LUSTRE/tests/cfg/$NAME.sh}
init_logging

MULTIOP=${MULTIOP:-multiop}
OPENFILE=${OPENFILE:-openfile}
MCREATE=${MCREATE:-mcreate}
MOUNT_2=${MOUNT_2:-"yes"}
FAIL_ON_ERROR=false

if [ $MDSCOUNT -ge 2 ]; then
	skip_env "Only run with single MDT for now" && exit
fi

check_and_setup_lustre

if [ $(lustre_version_code $SINGLEMDS) -lt $(version_code 2.4.53) ]; then
	skip_env "Need MDS version at least 2.4.53" && exit
fi

# $RUNAS_ID may get set incorrectly somewhere else
[ $UID -eq 0 -a $RUNAS_ID -eq 0 ] &&
	error "\$RUNAS_ID set to 0, but \$UID is also 0!"

check_runas_id $RUNAS_ID $RUNAS_GID $RUNAS

build_test_filter

# the standard state when starting a test is
# - no copytool
# - MOUNT2 done
# as some test changes the default, we need to re-make it
cleanup() {
	copytool_cleanup
	if ! is_mounted $MOUNT2
	then
		mount_client $MOUNT2
	fi
	changelog_cleanup
}

export HSMTOOL=${HSMTOOL:-"lhsmtool_posix"}
export HSMTOOL_VERBOSE=${HSMTOOL_VERBOSE:-""}
export HSMTOOL_BASE=$(basename "$HSMTOOL" | cut -f1 -d" ")
HSM_ARCHIVE=${HSM_ARCHIVE:-$TMP/arc}
HSM_ARCHIVE_NUMBER=2

MDT_PARAM="mdt.$FSNAME-MDT0000"
HSM_PARAM="$MDT_PARAM.hsm"

# archive is purged at copytool setup
HSM_ARCHIVE_PURGE=true

search_and_kill_copytool() {
	echo "Killing existing copy tools"
	killall -q $HSMTOOL_BASE || true
}

copytool_setup() {
	if pkill -CONT -x $HSMTOOL_BASE; then
		echo "Wakeup copytool"
		return
	fi

	if $HSM_ARCHIVE_PURGE; then
		echo "Purging archive"
		rm -rf $HSM_ARCHIVE/*
	fi

	echo "Starting copytool"
	mkdir -p $HSM_ARCHIVE
	# bandwidth is limited to 1MB/s so the copy time is known and
	# independent of hardware
	local CMD="$HSMTOOL $HSMTOOL_VERBOSE --hsm-root $HSM_ARCHIVE"
	CMD=$CMD" --daemon --bandwidth 1 $MOUNT"
	[[ -z "$1" ]] || CMD+=" --archive $1"

	echo "$CMD"
	$CMD  &
	trap cleanup EXIT
}

copytool_cleanup() {
	trap - EXIT
	pkill -INT -x $HSMTOOL_BASE || return 0
	sleep 1
	echo "Copytool is stopped"
}

copytool_suspend() {
	pkill -STOP -x $HSMTOOL_BASE || return 0
	echo "Copytool is suspended"
}

copytool_remove_backend() {
	local fid=$1
	local be=$(find $HSM_ARCHIVE -name $fid)
	echo "Remove from backend: $fid = $be"
	rm -f $be
}

import_file() {
	$HSMTOOL --archive $HSM_ARCHIVE_NUMBER --hsm-root $HSM_ARCHIVE \
		--import $1 $2 $MOUNT || error "import of $1 to $2 failed"
}

make_archive() {
	local file=$HSM_ARCHIVE/$1
	mkdir -p $(dirname $file)
	dd if=/dev/urandom of=$file count=32 bs=1000000 ||
		error "cannot create $file"
}

changelog_setup() {
	CL_USER=$(do_facet $SINGLEMDS $LCTL --device $MDT0\
		  changelog_register -n)
	do_facet $SINGLEMDS lctl set_param mdd.$MDT0.changelog_mask="+hsm"
	$LFS changelog_clear $MDT0 $CL_USER 0
}

changelog_cleanup() {
#	$LFS changelog $MDT0
	[[ -n "$CL_USER" ]] || return 0

	$LFS changelog_clear $MDT0 $CL_USER 0
	do_facet $SINGLEMDS lctl --device $MDT0 changelog_deregister $CL_USER
	CL_USER=
}

changelog_get_flags() {
	local mdt=$1
	local cltype=$2
	local fid=$3

	$LFS changelog $mdt | awk "/$cltype/ && /t=\[$fid\]/ {print \$5}"
}

get_hsm_param() {
	local param=$1
	local val=$(do_facet $SINGLEMDS $LCTL get_param -n $HSM_PARAM.$param)
	echo $val
}

set_hsm_param() {
	local param=$1
	local value=$2
	do_facet $SINGLEMDS $LCTL set_param -n $HSM_PARAM.$param=$value
	return $?
}

set_test_state() {
	local cmd=$1
	local target=$2
	do_facet $SINGLEMDS $LCTL set_param $MDT_PARAM.hsm_control=$cmd
	wait_result $SINGLEMDS "$LCTL get_param -n $MDT_PARAM.hsm_control"\
		$target 10 || error "cdt state is not $target"
}

cdt_set_sanity_policy() {
	# clear all
	do_facet $SINGLEMDS $LCTL set_param $HSM_PARAM.policy=-nra
	do_facet $SINGLEMDS $LCTL set_param $HSM_PARAM.policy=-nbr
	do_facet $SINGLEMDS $LCTL set_param $HSM_PARAM.policy=-gc
}

cdt_set_no_retry() {
	do_facet $SINGLEMDS $LCTL set_param $HSM_PARAM.policy=+nra
}

cdt_clear_no_retry() {
	do_facet $SINGLEMDS $LCTL set_param $HSM_PARAM.policy=-nra
}

cdt_set_no_blocking_restore() {
	do_facet $SINGLEMDS $LCTL set_param $HSM_PARAM.policy=+nbr
}

cdt_clear_no_blocking_restore() {
	do_facet $SINGLEMDS $LCTL set_param $HSM_PARAM.policy=-nbr
}

cdt_clear_mount_state() {
	# /!\ conf_param and set_param syntax differ +> we cannot use
	# $MDT_PARAM
	do_facet $SINGLEMDS $LCTL conf_param -d $FSNAME-MDT0000.mdt.hsm_control
}

cdt_set_mount_state() {
	# /!\ conf_param and set_param syntax differ +> we cannot use
	# $MDT_PARAM
	do_facet $SINGLEMDS $LCTL conf_param $FSNAME-MDT0000.mdt.hsm_control=$1
}

cdt_check_state() {
	local target=$1
	wait_result $SINGLEMDS\
		"$LCTL get_param -n $MDT_PARAM.hsm_control" "$target" 20 ||
			error "cdt state is not $target"
}

cdt_disable() {
	set_test_state disabled disabled
}

cdt_enable() {
	set_test_state enabled enabled
}

cdt_shutdown() {
	set_test_state shutdown stopped
}

cdt_purge() {
	set_test_state purge enabled
}

cdt_restart() {
	cdt_shutdown
	cdt_enable
	cdt_set_sanity_policy
}

need2clients() {
	if [[ $CLIENTCOUNT -lt 2 ]]; then
		skip "Need two or more clients, have $CLIENTCOUNT"
		return 1
	fi
	return 0
}

path2fid() {
	$LFS path2fid $1 | tr -d '[]'
}

get_hsm_flags() {
	local f=$1
	local u=$2

	if [[ $u == "user" ]]
	then
		local st=$($RUNAS $LFS hsm_state $f)
	else
		local st=$($LFS hsm_state $f)
		u=root
	fi

	[[ $? == 0 ]] || error "$LFS hsm_state $f failed (run as $u)"

	st=$(echo $st | cut -f 2 -d" " | tr -d "()," )
	echo $st
}

get_hsm_archive_id() {
	local f=$1
	local st=$($LFS hsm_state $f)
	[[ $? == 0 ]] || error "$LFS hsm_state $f failed"

	local ar=$(echo $st | grep "archive_id" | cut -f5 -d" " |
		   cut -f2 -d:)
	echo $ar
}

check_hsm_flags() {
	local f=$1
	local fl=$2

	local st=$(get_hsm_flags $f)
	[[ $st == $fl ]] || error "hsm flags on $f are $st != $fl"
}

check_hsm_flags_user() {
	local f=$1
	local fl=$2

	local st=$(get_hsm_flags $f user)
	[[ $st == $fl ]] || error "hsm flags on $f are $st != $fl"
}

copy_file() {
	local f=

	if [[ -d $2 ]]
	then
		f=$2/$(basename $1)
	else
		f=$2
	fi

	if [[ "$3" != 1 ]]
	then
		f=${f/$DIR/$DIR2}
	fi
	rm -f $f
	cp $1 $f || error "cannot copy $1 to $f"
	path2fid $f || error "cannot get fid on $f"
}

make_small() {
        local file2=${1/$DIR/$DIR2}
        dd if=/dev/urandom of=$file2 count=2 bs=1M conv=fsync ||
		error "cannot create $file2"
        path2fid $1 || error "cannot get fid on $1"
}

make_large_for_striping() {
	local file2=${1/$DIR/$DIR2}
	local sz=$($LCTL get_param -n lov.*-clilov-*.stripesize | head -1)
	dd if=/dev/urandom of=$file2 count=5 bs=$sz conv=fsync ||
		error "cannot create $file2"
	path2fid $1 || error "cannot get fid on $1"
}

make_large_for_progress() {
	local file2=${1/$DIR/$DIR2}
	# big file is large enough, so copy time is > 30s
	# so copytool make 1 progress
	# size is not a multiple of 1M to avoid stripe
	# aligment
	dd if=/dev/urandom of=$file2 count=39 bs=1000000 conv=fsync ||
		error "cannot create $file2"
	path2fid $1 || error "cannot get fid on $1"
}

make_large_for_progress_aligned() {
	local file2=${1/$DIR/$DIR2}
	# big file is large enough, so copy time is > 30s
	# so copytool make 1 progress
	# size is a multiple of 1M to have stripe
	# aligment
	dd if=/dev/urandom of=$file2 count=33 bs=1M conv=fsync ||
		error "cannot create $file2"
	path2fid $1 || error "cannot get fid on $1"
}

make_large_for_cancel() {
	local file2=${1/$DIR/$DIR2}
	# Copy timeout is 100s. 105MB => 105s
	dd if=/dev/urandom of=$file2 count=103 bs=1M conv=fsync ||
		error "cannot create $file2"
	path2fid $1 || error "cannot get fid on $1"
}

wait_result() {
	local facet=$1
	shift
	wait_update --verbose $(facet_active_host $facet) "$@"
}

wait_request_state()
{
	local fid=$1
	local request=$2
	local state=$3
	wait_result $SINGLEMDS "$LCTL get_param -n $HSM_PARAM.agent_actions |\
				grep $fid | grep action=$request |\
				cut -f 13 -d ' ' | cut -f 2 -d =" $state 100 ||
		error "request on $fid is not $state"
}

get_request_state()
{
	local fid=$1
	local request=$2
	do_facet $SINGLEMDS "$LCTL get_param -n $HSM_PARAM.agent_actions |\
				grep $fid | grep action=$request |\
				cut -f 13 -d ' ' | cut -f 2 -d ="
}

get_request_count()
{
	local fid=$1
	local request=$2
	do_facet $SINGLEMDS "$LCTL get_param -n $HSM_PARAM.agent_actions |\
				grep $fid | grep action=$request | wc -l"
}

wait_all_done()
{
	local timeout=$1
	wait_result $SINGLEMDS "$LCTL get_param -n $HSM_PARAM.agent_actions |\
		egrep 'WAITING|STARTED' " "" $timeout ||
	error "requests did not complete"
}

wait_for_grace_delay()
{
	local val=$(get_hsm_param grace_delay)
	sleep $val
}

my_uuid() {
	$LCTL get_param -n llite.$FSNAME-*.uuid
}

MDT0=$($LCTL get_param -n mdc.*.mds_server_uuid |
	awk '{gsub(/_UUID/,""); print $1}' | head -1)

# cleanup from previous bad setup
search_and_kill_copytool

# for recovery tests, coordinator needs to be started at mount
# so force it
# the lustre conf must be without hsm on (like for sanity.sh)
echo "Set HSM on and start"
cdt_set_mount_state enabled
cdt_check_state enabled

echo "Start copytool"
copytool_setup

# finished requests are quickly removed from list
set_hsm_param grace_delay 10

test_1() {
	mkdir -p $DIR/$tdir
	chmod 777 $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	$RUNAS touch $f

	# User flags
	check_hsm_flags_user $f "0x00000000"

	$RUNAS $LFS hsm_set --norelease $f ||
		error "user could not change hsm flags"
	check_hsm_flags_user $f "0x00000010"

	$RUNAS $LFS hsm_clear --norelease $f ||
		error "user could not clear hsm flags"
	check_hsm_flags_user $f "0x00000000"

	# User could not change those flags...
	$RUNAS $LFS hsm_set --exists $f &&
		error "user should not set this flag"
	check_hsm_flags_user $f "0x00000000"

	# ...but root can
	$LFS hsm_set --exists $f ||
		error "root could not change hsm flags"
	check_hsm_flags_user $f "0x00000001"

	$LFS hsm_clear --exists $f ||
		error "root could not clear hsm state"
	check_hsm_flags_user $f "0x00000000"

}
run_test 1 "lfs hsm flags root/non-root access"

test_2() {
	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	touch $f
	# New files are not dirty
	check_hsm_flags $f "0x00000000"

	# For test, we simulate an archived file.
	$LFS hsm_set --exists $f || error "user could not change hsm flags"
	check_hsm_flags $f "0x00000001"

	# chmod do not put the file dirty
	chmod 600 $f || error "could not chmod test file"
	check_hsm_flags $f "0x00000001"

	# chown do not put the file dirty
	chown $RUNAS_ID $f || error "could not chown test file"
	check_hsm_flags $f "0x00000001"

	# truncate put the file dirty
	$TRUNCATE $f 1 || error "could not truncate test file"
	check_hsm_flags $f "0x00000003"

	$LFS hsm_clear --dirty $f || error "could not clear hsm flags"
	check_hsm_flags $f "0x00000001"
}
run_test 2 "Check file dirtyness when doing setattr"

test_3() {
	mkdir -p $DIR/$tdir
	f=$DIR/$tdir/$tfile

	# New files are not dirty
	cp -p /etc/passwd $f
	check_hsm_flags $f "0x00000000"

	# For test, we simulate an archived file.
	$LFS hsm_set --exists $f ||
		error "user could not change hsm flags"
	check_hsm_flags $f "0x00000001"

	# Reading a file, does not set dirty
	cat $f > /dev/null || error "could not read file"
	check_hsm_flags $f "0x00000001"

	# Open for write without modifying data, does not set dirty
	openfile -f O_WRONLY $f || error "could not open test file"
	check_hsm_flags $f "0x00000001"

	# Append to a file sets it dirty
	cp -p /etc/passwd $f.append || error "could not create file"
	$LFS hsm_set --exists $f.append ||
		error "user could not change hsm flags"
	dd if=/etc/passwd of=$f.append bs=1 count=3\
	   conv=notrunc oflag=append status=noxfer ||
		error "could not append to test file"
	check_hsm_flags $f.append "0x00000003"

	# Modify a file sets it dirty
	cp -p /etc/passwd $f.modify || error "could not create file"
	$LFS hsm_set --exists $f.modify ||
		error "user could not change hsm flags"
	dd if=/dev/zero of=$f.modify bs=1 count=3\
	   conv=notrunc status=noxfer ||
		error "could not modify test file"
	check_hsm_flags $f.modify "0x00000003"

	# Open O_TRUNC sets dirty
	cp -p /etc/passwd $f.trunc || error "could not create file"
	$LFS hsm_set --exists $f.trunc ||
		error "user could not change hsm flags"
	cp /etc/group $f.trunc || error "could not override a file"
	check_hsm_flags $f.trunc "0x00000003"

	# Mmapped a file sets dirty
	cp -p /etc/passwd $f.mmap || error "could not create file"
	$LFS hsm_set --exists $f.mmap ||
		error "user could not change hsm flags"
	multiop $f.mmap OSMWUc || error "could not mmap a file"
	check_hsm_flags $f.mmap "0x00000003"
}
run_test 3 "Check file dirtyness when opening for write"

test_4() {
	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_small $f)

	$LFS hsm_cancel $f
	local st=$(get_request_state $fid CANCEL)
	[[ -z "$st" ]] || error "hsm_cancel must not be registered (state=$st)"
}
run_test 4 "Useless cancel must not be registered"

test_8() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)
	$LFS hsm_archive $f
	wait_request_state $fid ARCHIVE SUCCEED

	check_hsm_flags $f "0x00000009"

	copytool_cleanup
}
run_test 8 "Test default archive number"

test_9() {
	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)
	# we do not use the default one to be sure
	local new_an=$((HSM_ARCHIVE_NUMBER+ 1))
	copytool_cleanup
	copytool_setup $new_an
	$LFS hsm_archive --archive $new_an $f
	wait_request_state $fid ARCHIVE SUCCEED

	check_hsm_flags $f "0x00000009"

	copytool_cleanup
}
run_test 9 "Use of explict archive number, with dedicated copytool"

test_10a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir/d1
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/hosts $f)
	$LFS hsm_archive -a $HSM_ARCHIVE_NUMBER $f ||
		error "hsm_archive failed"
	wait_request_state $fid ARCHIVE SUCCEED

	local AFILE=$(ls $HSM_ARCHIVE/*/*/*/*/*/*/$fid) ||
		error "fid $fid not in archive $HSM_ARCHIVE"
	echo "Verifying content"
	diff $f $AFILE || error "archived file differs"
	echo "Verifying hsm state "
	check_hsm_flags $f "0x00000009"

	echo "Verifying archive number is $HSM_ARCHIVE_NUMBER"
	local st=$(get_hsm_archive_id $f)
	[[ $st == $HSM_ARCHIVE_NUMBER ]] ||
		error "Wrong archive number, $st != $HSM_ARCHIVE_NUMBER"

	copytool_cleanup

}
run_test 10a "Archive a file"

test_10b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/hosts $f)
	$LFS hsm_archive $f || error "archive request failed"
	wait_request_state $fid ARCHIVE SUCCEED

	$LFS hsm_archive $f || error "archive of non dirty file failed"
	local cnt=$(get_request_count $fid ARCHIVE)
	[[ "$cnt" == "1" ]] ||
		error "archive of non dirty file must not make a request"

	copytool_cleanup
}
run_test 10b "Archive of non dirty file must work without doing request"

test_10c() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/hosts $f)
	$LFS hsm_set --noarchive $f
	$LFS hsm_archive $f && error "archive a noarchive file must fail"

	copytool_cleanup
}
run_test 10c "Check forbidden archive"

test_11() {
	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	cp /etc/hosts $HSM_ARCHIVE/$tdir/$tfile
	local f=$DIR/$tdir/$tfile

	import_file $tdir/$tfile $f
	echo -n "Verifying released state: "
	check_hsm_flags $f "0x0000000d"

	local LSZ=$(stat -c "%s" $f)
	local ASZ=$(stat -c "%s" $HSM_ARCHIVE/$tdir/$tfile)

	echo "Verifying imported size $LSZ=$ASZ"
	[[ $LSZ -eq $ASZ ]] || error "Incorrect size $LSZ != $ASZ"
	echo -n "Verifying released pattern: "
	local PTRN=$($GETSTRIPE -L $f)
	echo $PTRN
	[[ $PTRN == 80000001 ]] || error "Is not released"
	local fid=$(path2fid $f)
	echo "Verifying new fid $fid in archive"

	local AFILE=$(ls $HSM_ARCHIVE/*/*/*/*/*/*/$fid) ||
		error "fid $fid not in archive $HSM_ARCHIVE"
}
run_test 11 "Import a file"

test_12a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	cp /etc/hosts $HSM_ARCHIVE/$tdir/$tfile
	local f=$DIR/$tdir/$tfile
	import_file $tdir/$tfile $f
	local f=$DIR2/$tdir/$tfile
	echo "Verifying released state: "
	check_hsm_flags $f "0x0000000d"

	local fid=$(path2fid $f)
	$LFS hsm_restore $f
	wait_request_state $fid RESTORE SUCCEED

	echo "Verifying file state: "
	check_hsm_flags $f "0x00000009"

	diff -q $HSM_ARCHIVE/$tdir/$tfile $f

	[[ $? -eq 0 ]] || error "Restored file differs"

	copytool_cleanup
}
run_test 12a "Restore an imported file explicitly"

test_12b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	cp /etc/hosts $HSM_ARCHIVE/$tdir/$tfile
	local f=$DIR/$tdir/$tfile
	import_file $tdir/$tfile $f
	echo "Verifying released state: "
	check_hsm_flags $f "0x0000000d"

	cat $f > /dev/null || error "File read failed"

	echo "Verifying file state after restore: "
	check_hsm_flags $f "0x00000009"

	diff -q $HSM_ARCHIVE/$tdir/$tfile $f

	[[ $? -eq 0 ]] || error "Restored file differs"

	copytool_cleanup
}
run_test 12b "Restore an imported file implicitly"

test_12c() {
	[ "$OSTCOUNT" -lt "2" ] && skip_env "skipping 2-stripe test" && return

	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	$LFS setstripe -c 2 $f
	local fid=$(make_large_for_striping $f)
	local FILE_CRC=$(md5sum $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f || error "release $f failed"

	echo "$FILE_CRC" | md5sum -c

	[[ $? -eq 0 ]] || error "Restored file differs"

	copytool_cleanup
}
run_test 12c "Restore a file with stripe of 2"

test_12d() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/hosts $f)
	$LFS hsm_restore $f || error "restore of non archived file failed"
	local cnt=$(get_request_count $fid RESTORE)
	[[ "$cnt" == "0" ]] ||
		error "restore non archived must not make a request"
	$LFS hsm_archive $f ||
		error "archive request failed"
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_restore $f ||
		error "restore of non released file failed"
	local cnt=$(get_request_count $fid RESTORE)
	[[ "$cnt" == "0" ]] ||
		error "restore a non dirty file must not make a request"

	copytool_cleanup
}
run_test 12d "Restore of a non archived, non released file must work"\
		" without doing request"

test_12e() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/hosts $f)
	$LFS hsm_archive $f || error "archive request failed"
	wait_request_state $fid ARCHIVE SUCCEED

	# make file dirty
	cat /etc/hosts >> $f
	sync
	$LFS hsm_state $f

	$LFS hsm_restore $f && error "restore a dirty file must fail"

	copytool_cleanup
}
run_test 12e "Check forbidden restore"

test_12f() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/hosts $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f || error "release of $f failed"
	$LFS hsm_restore $f
	wait_request_state $fid RESTORE SUCCEED

	echo -n "Verifying file state: "
	check_hsm_flags $f "0x00000009"

	diff -q /etc/hosts $f

	[[ $? -eq 0 ]] || error "Restored file differs"

	copytool_cleanup
}
run_test 12f "Restore a released file explicitly"

test_12g() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/hosts $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f || error "release of $f failed"

	diff -q /etc/hosts $f
	local st=$?

	# we check we had a restore done
	wait_request_state $fid RESTORE SUCCEED

	[[ $st -eq 0 ]] || error "Restored file differs"

	copytool_cleanup
}
run_test 12g "Restore a released file implicitly"

test_12h() {
	need2clients || return 0

	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/hosts $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f || error "release of $f failed"

	do_node $CLIENT2 diff -q /etc/hosts $f
	local st=$?

	# we check we had a restore done
	wait_request_state $fid RESTORE SUCCEED

	[[ $st -eq 0 ]] || error "Restored file differs"

	copytool_cleanup
}
run_test 12h "Restore a released file implicitly from a second node"

test_12m() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)
	$LFS hsm_archive $f || error "archive of $f failed"
	wait_request_state $fid ARCHIVE SUCCEED

	$LFS hsm_release $f || error "release of $f failed"

	cmp /etc/passwd $f

	[[ $? -eq 0 ]] || error "Restored file differs"

	copytool_cleanup
}
run_test 12m "Archive/release/implicit restore"

test_12n() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	cp /etc/hosts $HSM_ARCHIVE/$tdir/$tfile
	local f=$DIR/$tdir/$tfile
	import_file $tdir/$tfile $f

	cmp /etc/hosts $f || error "Restored file differs"

	$LFS hsm_release $f || error "release of $f failed"

	copytool_cleanup
}
run_test 12n "Import/implicit restore/release"

test_13() {
	# test needs a running copytool
	copytool_setup

	local ARC_SUBDIR="import.orig"
	local d=""
	local f=""

	# populate directory to be imported
	for d in $(seq 1 10); do
		local CURR_DIR="$HSM_ARCHIVE/$ARC_SUBDIR/dir.$d"
		mkdir -p "$CURR_DIR"
		for f in $(seq 1 10); do
			CURR_FILE="$CURR_DIR/$tfile.$f"
			# write file-specific data
			echo "d=$d, f=$f, dir=$CURR_DIR, file=$CURR_FILE"\
				> $CURR_FILE
		done
	done
	# import to Lustre
	import_file "$ARC_SUBDIR" $DIR/$tdir
	# diff lustre content and origin (triggers file restoration)
	# there must be 10x10 identical files, and no difference
	local cnt_ok=$(diff -rs $HSM_ARCHIVE/$ARC_SUBDIR \
		       $DIR/$tdir/$ARC_SUBDIR |
		grep identical | wc -l)
	local cnt_diff=$(diff -r $HSM_ARCHIVE/$ARC_SUBDIR \
			 $DIR/$tdir/$ARC_SUBDIR |
		wc -l)

	[ $cnt_diff -eq 0 ] ||
		error "$cnt_diff imported files differ from read data"
	[ $cnt_ok -eq 100 ] ||
		error "not enough identical files ($cnt_ok != 100)"

	copytool_cleanup
}
run_test 13 "Recursively import and restore a directory"

test_14() {
	# test needs a running copytool
	copytool_setup

	# archive a file
	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_small $f)
	local sum=$(md5sum $f | awk '{print $1}')
	$LFS hsm_archive $f || error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED

	# delete the file
	rm -f $f
	# create released file (simulate llapi_hsm_import call)
	touch $f
	local fid2=$(path2fid $f)
	$LFS hsm_set --archived --exists $f || error "could not force hsm flags"
	$LFS hsm_release $f || error "could not release file"

	# rebind the archive to the newly created file
	echo "rebind $fid to $fid2"
	$HSMTOOL --archive $HSM_ARCHIVE_NUMBER --hsm-root="$HSM_ARCHIVE"\
	 --rebind $fid $fid2 $DIR ||
		error "could not rebind file"

	# restore file and compare md5sum
	local sum2=$(md5sum $f | awk '{print $1}')

	[[ $sum == $sum2 ]] || error "md5sum mismatch after restore"

	copytool_cleanup
}
run_test 14 "Rebind archived file to a new fid"

test_15() {
	# test needs a running copytool
	copytool_setup

	# archive files
	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local count=5
	local tmpfile=$TMP/tmp.$$

	local fids=()
	local sums=()
	for i in $(seq 1 $count); do
		fids[$i]=$(make_small $f.$i)
		sums[$i]=$(md5sum $f.$i | awk '{print $1}')
		$LFS hsm_archive $f.$i || error "could not archive file"
	done
	wait_all_done $(($count*60))

	:>$tmpfile
	# delete the files
	for i in $(seq 1 $count); do
		rm -f $f.$i
		touch $f.$i
		local fid2=$(path2fid $f.$i)
		# add the rebind operation to the list
		echo ${fids[$i]} $fid2 >> $tmpfile

		# set it released (simulate llapi_hsm_import call)
		$LFS hsm_set --archived --exists $f.$i ||
			error "could not force hsm flags"
		$LFS hsm_release $f.$i || error "could not release file"
	done
	nl=$(wc -l < $tmpfile)
	[[ $nl == $count ]] || error "$nl files in list, $count expected"

	echo "rebind list of files"
	$HSMTOOL --archive $HSM_ARCHIVE_NUMBER --hsm-root="$HSM_ARCHIVE"\
	 --rebind $tmpfile $DIR ||
		error "could not rebind file list"

	# restore files and compare md5sum
	for i in $(seq 1 $count); do
		local sum2=$(md5sum $f.$i | awk '{print $1}')
		[[ $sum2 == ${sums[$i]} ]] ||
		    error "md5sum mismatch after restore ($sum2 != ${sums[$i]})"
	done

	rm -f $tmpfile
	copytool_cleanup
}
run_test 15 "Rebind a list of files"

test_16() {
	# test needs a running copytool
	copytool_setup

	local ref=/tmp/ref
	# create a known size file so we can verify transfer speed
	# 20 MB <-> 20s
	local goal=20
	dd if=/dev/zero of=$ref bs=1M count=20

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file $ref $f)
	rm $ref
	local start=$(date +%s)
	$LFS hsm_archive $f
	wait_request_state $fid ARCHIVE SUCCEED
	local end=$(date +%s)
	local duration=$((end - start))

	[[ $duration -ge $goal ]] ||
		error "Transfer is too fast $duration < $goal"

	copytool_cleanup
}
run_test 16 "Test CT bandwith control option"

test_20() {
	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	touch $f || error "touch $f failed"

	# Could not release a non-archived file
	$LFS hsm_release $f && error "release should not succeed"

	# For following tests, we must test them with HS_ARCHIVED set
	$LFS hsm_set --exists --archived $f || error "could not add flag"

	# Could not release a file if no-release is set
	$LFS hsm_set --norelease $f || error "could not add flag"
	$LFS hsm_release $f && error "release should not succeed"
	$LFS hsm_clear --norelease $f || error "could not remove flag"

	# Could not release a file if lost
	$LFS hsm_set --lost $f || error "could not add flag"
	$LFS hsm_release $f && error "release should not succeed"
	$LFS hsm_clear --lost $f || error "could not remove flag"

	# Could not release a file if dirty
	$LFS hsm_set --dirty $f || error "could not add flag"
	$LFS hsm_release $f && error "release should not succeed"
	$LFS hsm_clear --dirty $f || error "could not remove flag"
}
run_test 20 "Release is not permitted"

test_21() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/test_release

	# Create a file and check its states
	local fid=$(make_small $f)
	check_hsm_flags $f "0x00000000"

	$LFS hsm_archive $f || error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED

	[ $(stat -c "%b" $f) -ne "0" ] || error "wrong block number"
	local sz=$(stat -c "%s" $f)
	[ $sz -ne "0" ] || error "file size should not be zero"

	# Release and check states
	$LFS hsm_release $f || error "could not release file"
	check_hsm_flags $f "0x0000000d"

	[ $(stat -c "%b" $f) -eq "0" ] || error "wrong block number"
	[ $(stat -c "%s" $f) -eq $sz ] || error "wrong file size"

	# Check we can release an file without stripe info
	f=$f.nolov
	$MCREATE $f
	fid=$(path2fid $f)
	check_hsm_flags $f "0x00000000"
	$LFS hsm_archive $f || error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED

	# Release and check states
	$LFS hsm_release $f || error "could not release file"
	check_hsm_flags $f "0x0000000d"

	# Release again a file that is already released is OK
	$LFS hsm_release $f || fail "second release should succeed"
	check_hsm_flags $f "0x0000000d"

	copytool_cleanup
}
run_test 21 "Simple release tests"

test_22() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/test_release
	local swap=$DIR/$tdir/test_swap

	# Create a file and check its states
	local fid=$(make_small $f)
	check_hsm_flags $f "0x00000000"

	$LFS hsm_archive $f || error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED

	# Release and check states
	$LFS hsm_release $f || error "could not release file"
	check_hsm_flags $f "0x0000000d"

	make_small $swap
	$LFS swap_layouts $swap $f && error "swap_layouts should failed"

	true
	copytool_cleanup
}
run_test 22 "Could not swap a release file"

test_23() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/test_mtime

	# Create a file and check its states
	local fid=$(make_small $f)
	check_hsm_flags $f "0x00000000"

	$LFS hsm_archive $f || error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED

	# Set modification time in the past
	touch -m -a -d @978261179 $f

	# Release and check states
	$LFS hsm_release $f || error "could not release file"
	check_hsm_flags $f "0x0000000d"

	local MTIME=$(stat -c "%Y" $f)
	local ATIME=$(stat -c "%X" $f)
	[ $MTIME -eq "978261179" ] || fail "bad mtime: $MTIME"
	[ $ATIME -eq "978261179" ] || fail "bad atime: $ATIME"

	copytool_cleanup
}
run_test 23 "Release does not change a/mtime (utime)"

test_24() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/test_mtime

	# Create a file and check its states
	local fid=$(make_small $f)
	check_hsm_flags $f "0x00000000"

	# make mtime is different
	sleep 1
	echo "append" >> $f
	local MTIME=$(stat -c "%Y" $f)
	local ATIME=$(stat -c "%X" $f)

	$LFS hsm_archive $f || error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED

	# Release and check states
	$LFS hsm_release $f || error "could not release file"
	check_hsm_flags $f "0x0000000d"

	[ "$(stat -c "%Y" $f)" -eq "$MTIME" ] ||
		error "mtime should be $MTIME"

	[ "$(stat -c "%X" $f)" -eq "$ATIME" ] ||
		error "atime should be $ATIME"

	copytool_cleanup
}
run_test 24 "Release does not change a/mtime (i/o)"

test_25a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	cp /etc/hosts $HSM_ARCHIVE/$tdir/$tfile
	local f=$DIR/$tdir/$tfile

	import_file $tdir/$tfile $f

	$LFS hsm_set --lost $f

	md5sum $f
	local st=$?

	[[ $st == 1 ]] || error "lost file access should failed (returns $st)"

	copytool_cleanup
}
run_test 25a "Restore lost file (HS_LOST flag) from import"\
	     " (Operation not permitted)"

test_25b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED

	$LFS hsm_release $f
	$LFS hsm_set --lost $f
	md5sum $f
	st=$?

	[[ $st == 1 ]] || error "lost file access should failed (returns $st)"

	copytool_cleanup
}
run_test 25b "Restore lost file (HS_LOST flag) after release"\
	     " (Operation not permitted)"

test_26() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED

	$LFS hsm_remove $f
	wait_request_state $fid REMOVE SUCCEED

	check_hsm_flags $f "0x00000000"

	copytool_cleanup
}
run_test 26 "Remove the archive of a valid file"

test_27a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	make_archive $tdir/$tfile
	local f=$DIR/$tdir/$tfile
	import_file $tdir/$tfile $f
	local fid=$(path2fid $f)

	$LFS hsm_remove $f

	[[ $? != 0 ]] || error "Remove of a released file should fail"

	copytool_cleanup
}
run_test 27a "Remove the archive of an imported file (Operation not permitted)"

test_27b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	$LFS hsm_remove $f

	[[ $? != 0 ]] || error "Remove of a released file should fail"

	copytool_cleanup
}
run_test 27b "Remove the archive of a relased file (Operation not permitted)"

test_28() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED

	cdt_disable
	$LFS hsm_remove $f

	rm -f $f

	cdt_enable

	wait_request_state $fid REMOVE SUCCEED

	copytool_cleanup
}
run_test 28 "Concurrent archive/file remove"

test_30a() {
	# restore at exec cannot work on agent node (because of Linux kernel
	# protection of executables)
	need2clients || return 0

	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	cp -p /bin/true $HSM_ARCHIVE/$tdir/$tfile
	local f=$DIR/$tdir/true
	import_file $tdir/$tfile $f

	local fid=$(path2fid $f)

	# set no retry action mode
	cdt_set_no_retry
	do_node $CLIENT2 $f
	local st=$?

	# cleanup
	# remove no try action mode
	cdt_clear_no_retry
	$LFS hsm_state $f

	[[ $st == 0 ]] || error "Failed to exec a released file"

	copytool_cleanup
}
run_test 30a "Restore at exec (import case)"

test_30b() {
	# restore at exec cannot work on agent node (because of Linux kernel
	# protection of executables)
	need2clients || return 0

	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/true
	local fid=$(copy_file /bin/true $f)
	chmod 755 $f
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f
	$LFS hsm_state $f
	# set no retry action mode
	cdt_set_no_retry
	do_node $CLIENT2 $f
	local st=$?

	# cleanup
	# remove no try action mode
	cdt_clear_no_retry
	$LFS hsm_state $f

	[[ $st == 0 ]] || error "Failed to exec a released file"

	copytool_cleanup
}
run_test 30b "Restore at exec (release case)"

restore_and_check_size()
{
	local f=$1
	local fid=$2
	local s=$(stat -c "%s" $f)
	local n=$s
	local st=$(get_hsm_flags $f)
	local err=0
	local cpt=0
	$LFS hsm_restore $f
	while [[ "$st" != "0x00000009" && $cpt -le 10 ]]
	do
		n=$(stat -c "%s" $f)
		# we echo in both cases to show stat is not
		# hang
		if [[ $n != $s ]]
		then
			echo "size seen is $n != $s"
			err=1
		else
			echo "size seen is right: $n == $s"
		fi
		st=$(get_hsm_flags $f)
		sleep 10
		cpt=$((cpt + 1))
	done
	if [[ $cpt -lt 10 ]]
	then
		echo " restore is too long"
	else
		echo " "done
	fi
	wait_request_state $fid RESTORE SUCCEED
	return $err
}

test_31a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	make_archive $tdir/$tfile
	local f=$DIR/$tdir/$tfile
	import_file $tdir/$tfile $f
	local fid=$($LFS path2fid $f)
	HSM_ARCHIVE_PURGE=false copytool_setup

	restore_and_check_size $f $fid
	local err=$?

	[[ $err -eq 0 ]] || error "File size changed during restore"

	copytool_cleanup
}
run_test 31a "Import a large file and check size during restore"


test_31b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	restore_and_check_size $f $fid
	local err=$?

	[[ $err -eq 0 ]] || error "File size changed during restore"

	copytool_cleanup
}
run_test 31b "Restore a large unaligned file and check size during restore"

test_31c() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress_aligned $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	restore_and_check_size $f $fid
	local err=$?

	[[ $err -eq 0 ]] || error "File size changed during restore"

	copytool_cleanup
}
run_test 31c "Restore a large aligned file and check size during restore"

test_33() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	md5sum $f >/dev/null &
	local pid=$!
	wait_request_state $fid RESTORE STARTED

	kill -15 $pid
	sleep 1

	# Check restore trigger process was killed
	local killed=$(ps -o pid,comm hp $pid >/dev/null)

	$LFS hsm_cancel $f

	wait_request_state $fid RESTORE CANCELED
	wait_request_state $fid CANCEL SUCCEED

	[ -z $killed ] ||
		error "Cannot kill process waiting for restore ($killed)"

	copytool_cleanup
}
run_test 33 "Kill a restore waiting process"

test_34() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	md5sum $f >/dev/null &
	local pid=$!
	wait_request_state $fid RESTORE STARTED

	rm $f || error "rm $f failed"
	# rm must not block during restore
	wait_request_state $fid RESTORE STARTED

	wait_request_state $fid RESTORE SUCCEED
	# check md5sum pgm finished
	local there=$(ps -o pid,comm hp $pid >/dev/null)
	[[ -z $there ]] || error "Restore initiator does not exit"

	local rc=$(wait $pid)
	[[ $rc -eq 0 ]] || error "Restore initiator failed with $rc"

	copytool_cleanup
}
run_test 34 "Remove file during restore"

test_35() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local f1=$DIR/$tdir/$tfile-1
	local fid=$(make_large_for_progress $f)
	local fid1=$(copy_file /etc/passwd $f1)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	md5sum $f >/dev/null &
	local pid=$!
	wait_request_state $fid RESTORE STARTED

	mv $f1 $f || error "mv $f1 $f failed"
	# mv must not block during restore
	wait_request_state $fid RESTORE STARTED

	wait_request_state $fid RESTORE SUCCEED
	# check md5sum pgm finished
	local there=$(ps -o pid,comm hp $pid >/dev/null)
	[[ -z $there ]] || error "Restore initiator does not exit"

	local rc=$(wait $pid)
	[[ $rc -eq 0 ]] || error "Restore initiator failed with $rc"

	fid2=$(path2fid $f)
	[[ $fid2 == $fid1 ]] || error "Wrong fid after mv $fid2 != $fid1"

	copytool_cleanup
}
run_test 35 "Overwrite file during restore"

test_36() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	md5sum $f >/dev/null &
	local pid=$!
	wait_request_state $fid RESTORE STARTED

	mv $f $f.new
	# rm must not block during restore
	wait_request_state $fid RESTORE STARTED

	wait_request_state $fid RESTORE SUCCEED
	# check md5sum pgm finished
	local there=$(ps -o pid,comm hp $pid >/dev/null)
	[[ -z $there ]] ||
		error "Restore initiator does not exit"

	local rc=$(wait $pid)
	[[ $rc -eq 0 ]] ||
		error "Restore initiator failed with $rc"

	copytool_cleanup
}
run_test 36 "Move file during restore"

multi_archive() {
	local prefix=$1
	local count=$2
	local n=""

	for n in $(seq 1 $count); do
		$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $prefix.$n
	done
	echo "$count archive requests submitted"
}

test_40() {
	local stream_count=4
	local file_count=100
	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local i=""
	local p=""
	local fid=""

	for i in $(seq 1 $file_count); do
		for p in $(seq 1 $stream_count); do
			fid=$(copy_file /etc/hosts $f.$p.$i)
		done
	done
	copytool_setup
	# to be sure wait_all_done will not be mislead by previous tests
	cdt_purge
	wait_for_grace_delay
	typeset -a pids
	# start archive streams in background (archive files in parallel)
	for p in $(seq 1 $stream_count); do
		multi_archive $f.$p $file_count &
		pids[$p]=$!
	done
	echo -n  "Wait for all requests being enqueued..."
	wait ${pids[*]}
	echo OK
	wait_all_done 100
	copytool_cleanup
}
run_test 40 "Parallel archive requests"

test_52() {
	# test needs a running copytool
	copytool_setup

	# Test behave badly if 2 mount points are present
	umount_client $MOUNT2

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/motd $f 1)

	$LFS hsm_archive $f || error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED
	check_hsm_flags $f "0x00000009"

	multiop_bg_pause $f O_c || error "multiop failed"
	local MULTIPID=$!

	mds_evict_client
	client_up || client_up || true

	kill -USR1 $MULTIPID
	wait $MULTIPID || error "multiop close failed"

	check_hsm_flags $f "0x0000000b"

	# Restore test environment
	mount_client $MOUNT2

	copytool_cleanup
}
run_test 52 "Opened for write file on an evicted client should be set dirty"

test_53() {
	# test needs a running copytool
	copytool_setup

	# Checks are wrong with 2 mount points
	umount_client $MOUNT2

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/motd $f 1)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f ||
		error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED
	check_hsm_flags $f "0x00000009"

	multiop_bg_pause $f o_c || error "multiop failed"
	MULTIPID=$!

	mds_evict_client
	client_up || client_up || true

	kill -USR1 $MULTIPID
	wait $MULTIPID || error "multiop close failed"

	check_hsm_flags $f "0x00000009"

	mount_client $MOUNT2

	copytool_cleanup
}
run_test 53 "Opened for read file on an evicted client should not be set dirty"

test_54() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_small $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f ||
		error "could not archive file"
	wait_request_state $fid ARCHIVE STARTED

	check_hsm_flags $f "0x00000001"

	# Avoid coordinator resending this request as soon it has failed.
	cdt_set_no_retry

	echo "foo" >> $f
	sync
	wait_request_state $fid ARCHIVE FAILED

	check_hsm_flags $f "0x00000003"

	cdt_clear_no_retry
	copytool_cleanup
}
run_test 54 "Write during an archive cancels it"

test_55() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_small $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f ||
		error "could not archive file"
	wait_request_state $fid ARCHIVE STARTED

	check_hsm_flags $f "0x00000001"

	# Avoid coordinator resending this request as soon it has failed.
	cdt_set_no_retry

	$TRUNCATE $f 1024 || error "truncate failed"
	sync
	wait_request_state $fid ARCHIVE FAILED

	check_hsm_flags $f "0x00000003"

	cdt_clear_no_retry
	copytool_cleanup
}
run_test 55 "Truncate during an archive cancels it"

test_56() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f ||
		error "could not archive file"
	wait_request_state $fid ARCHIVE STARTED

	check_hsm_flags $f "0x00000001"

	# Change metadata and sync to be sure we are not changing only
	# in memory.
	chmod 644 $f
	chgrp sys $f
	sync
	wait_request_state $fid ARCHIVE SUCCEED

	check_hsm_flags $f "0x00000009"

	copytool_cleanup
}
run_test 56 "Setattr during an archive is ok"

test_57() {
	# Need one client for I/O, one for request
	need2clients || return 0

	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/test_archive_remote
	# Create a file on a remote node
	do_node $CLIENT2 "dd if=/dev/urandom of=$f bs=1M "\
		"count=2 conv=fsync"

	# And archive it
	do_node $CLIENT2 "$LFS hsm_archive -a $HSM_ARCHIVE_NUMBER $f" ||
		error "hsm_archive failed"
	local fid=$(path2fid $f)
	wait_request_state $fid ARCHIVE SUCCEED

	# Release and implicit restore it
	do_node $CLIENT2 "$LFS hsm_release $f" ||
		error "hsm_release failed"
	do_node $CLIENT2 "md5sum $f" ||
		error "hsm_restore failed"

	wait_request_state $fid RESTORE SUCCEED

	copytool_cleanup
}
run_test 57 "Archive a file with dirty cache on another node"

test_58() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_small $f)

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f ||
		error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED

	$LFS hsm_release $f || error "could not release file"

	$TRUNCATE $f 0 || error "truncate failed"
	sync

	local sz=$(stat -c %s $f)
	[[ $sz == 0 ]] || error "size after truncate is $sz != 0"

	$LFS hsm_state $f

	check_hsm_flags $f "0x0000000b"

	local state=$(get_request_state $fid RESTORE)
	[[ "$state" == "" ]] ||
		error "truncate 0 trigs a restore, state = $state"

	copytool_cleanup
}
run_test 58 "Truncate 0 on a released file must not trigger restore"

test_59() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)
	local ref=$f-ref
	cp $f $ref
	local sz=$(stat -c %s $ref)
	sz=$((sz / 2))
	$TRUNCATE $ref $sz

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f ||
		error "could not archive file"
	wait_request_state $fid ARCHIVE SUCCEED

	$LFS hsm_release $f || error "could not release file"

	$TRUNCATE $f $sz || error "truncate failed"
	sync

	local sz1=$(stat -c %s $f)
	[[ $sz1 == $sz ]] || error "size after truncate is $sz1 != $sz"

	$LFS hsm_state $f

	check_hsm_flags $f "0x0000000b"

	local state=$(get_request_state $fid RESTORE)
	[[ "$state" == "SUCCEED" ]] ||
		error "truncate $sz does not trig a successfull restore,"\
		      " state = $state"

	cmp $ref $f || error "file data wrong after truncate"

	copytool_cleanup
}
run_test 59 "Truncate != 0 on a released file"

test_90() {
	file_count=57
	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local FILELIST=/tmp/filelist.txt
	local i=""

	rm -f $FILELIST
	for i in $(seq 1 $file_count); do
		fid=$(copy_file /etc/hosts $f.$i)
		echo $f.$i >> $FILELIST
	done
	copytool_setup
	# to be sure wait_all_done will not be mislead by previous tests
	cdt_purge
	wait_for_grace_delay
	$LFS hsm_archive --filelist $FILELIST ||
		error "cannot archive a file list"
	wait_all_done 100
	$LFS hsm_release --filelist $FILELIST ||
		error "cannot release a file list"
	$LFS hsm_restore --filelist $FILELIST ||
		error "cannot restore a file list"
	wait_all_done 100
	copytool_cleanup
}
run_test 90 "Archive/restore a file list"

double_verify_reset_ham_param() {
	local p=$1
	echo "Testing $HSM_PARAM.$p"
	local val=$(get_hsm_param $p)
	local save=$val
	local val2=$(($val * 2))
	set_hsm_param $p $val2
	val=$(get_hsm_param $p)
	[[ $val == $val2 ]] ||
		error "$HSM_PARAM.$p: $val != $val2 should be (2 * $save)"
	echo "Set $p to 0 must failed"
	set_hsm_param $p 0
	local rc=$?
	# restore value
	set_hsm_param $p $save

	if [[ $rc == 0 ]]
	then
		error "we must not be able to set $HSM_PARAM.$p to 0"
	fi
}

test_100() {
	double_verify_reset_ham_param loop_period
	double_verify_reset_ham_param grace_delay
	double_verify_reset_ham_param request_timeout
	double_verify_reset_ham_param max_requests
}
run_test 100 "Set coordinator /proc tunables"

test_102() {
	cdt_disable
	cdt_enable
	cdt_restart
}
run_test 102 "Verify coordinator control"

test_103() {
	# test needs a running copytool
	copytool_setup

	local i=""
	local fid=""

	mkdir -p $DIR/$tdir
	for i in $(seq 1 20); do
		fid=$(copy_file /etc/passwd $DIR/$tdir/$i)
	done
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $DIR/$tdir/*

	cdt_purge

	echo "Current requests"
	local res=$(do_facet $SINGLEMDS "$LCTL get_param -n\
			$HSM_PARAM.agent_actions |\
			grep -v CANCELED | grep -v SUCCEED | grep -v FAILED")

	[[ -z "$res" ]] || error "Some request have not been canceled"

	copytool_cleanup
}
run_test 103 "Purge all requests"

DATA=CEA
DATAHEX='[434541]'
test_104() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	# if cdt is on, it can serve too quickly the request
	cdt_disable
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER --data $DATA $f
	local data1=$(do_facet $SINGLEMDS "$LCTL get_param -n\
			$HSM_PARAM.agent_actions |\
			grep $fid | cut -f16 -d=")
	cdt_enable

	[[ "$data1" == "$DATAHEX" ]] ||
		error "Data field in records is ($data1) and not ($DATAHEX)"

	copytool_cleanup
}
run_test 104 "Copy tool data field"

test_105() {
	mkdir -p $DIR/$tdir
	local i=""

	cdt_disable
	for i in $(seq -w 1 10); do
		cp /etc/passwd $DIR/$tdir/$i
		$LFS hsm_archive $DIR/$tdir/$i
	done
	local reqcnt1=$(do_facet $SINGLEMDS "$LCTL get_param -n\
			$HSM_PARAM.agent_actions |\
			grep WAITING | wc -l")
	cdt_restart
	cdt_disable
	local reqcnt2=$(do_facet $SINGLEMDS "$LCTL get_param -n\
			$HSM_PARAM.agent_actions |\
			grep WAITING | wc -l")
	cdt_enable
	cdt_purge
	[[ "$reqcnt1" == "$reqcnt2" ]] ||
		error "Requests count after shutdown $reqcnt2 != "\
		      "before shutdown $reqcnt1"
}
run_test 105 "Restart of coordinator"

test_106() {
	# Test behave badly if 2 mount points are present
	umount_client $MOUNT2

	# test needs a running copytool
	copytool_setup

	local uuid=$(my_uuid)
	local agent=$(do_facet $SINGLEMDS $LCTL get_param -n $HSM_PARAM.agents |
		grep $uuid)
	copytool_cleanup
	[[ ! -z "$agent" ]] || error "My uuid $uuid not found in agent list"
	local agent=$(do_facet $SINGLEMDS $LCTL get_param -n $HSM_PARAM.agents |
		grep $uuid)
	[[ -z "$agent" ]] ||
		error "My uuid $uuid still found in agent list,"\
		      " after copytool shutdown"
	copytool_setup
	local agent=$(do_facet $SINGLEMDS $LCTL get_param -n $HSM_PARAM.agents |
		grep $uuid)
	copytool_cleanup
	[[ ! -z "$agent" ]] ||
		error "My uuid $uuid not found in agent list after"\
		      " copytool restart"

	# Restore test environment
	mount_client $MOUNT2
}
run_test 106 "Copytool register/unregister"

test_107() {
	# test needs a running copytool
	copytool_setup
	# create and archive file
	mkdir -p $DIR/$tdir
	local f1=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f1)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f1
	wait_request_state $fid ARCHIVE SUCCEED
	# shutdown and restart MDS
	fail $SINGLEMDS
	# check the copytool still gets messages from MDT
	local f2=$DIR/$tdir/2
	local fid=$(copy_file /etc/passwd $f2)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f2
	# main check of this sanity: this request MUST succeed
	wait_request_state $fid ARCHIVE SUCCEED
	copytool_cleanup
}
run_test 107 "Copytool re-register after MDS restart"

test_110a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	cp /etc/passwd $HSM_ARCHIVE/$tdir/$tfile
	local f=$DIR/$tdir/$tfile
	import_file $tdir/$tfile $f
	local fid=$(path2fid $f)

	cdt_set_no_blocking_restore
	md5sum $f
	local st=$?

	# cleanup
	wait_request_state $fid RESTORE SUCCEED
	cdt_clear_no_blocking_restore

	# Test result
	[[ $st == 1 ]] ||
		error "md5sum returns $st != 1, "\
			"should also perror ENODATA (No data available)"

	copytool_cleanup
}
run_test 110a "Non blocking restore policy (import case)"

test_110b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	cdt_set_no_blocking_restore
	md5sum $f
	local st=$?

	# cleanup
	wait_request_state $fid RESTORE SUCCEED
	cdt_clear_no_blocking_restore

	# Test result
	[[ $st == 1 ]] ||
		error "md5sum returns $st != 1, "\
			"should also perror ENODATA (No data available)"

	copytool_cleanup
}
run_test 110b "Non blocking restore policy (release case)"

test_111a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	local f=$DIR/$tdir/$tfile
	cp /etc/passwd $HSM_ARCHIVE/$tdir/$tfile
	import_file $tdir/$tfile $f
	local fid=$(path2fid $f)

	cdt_set_no_retry

	copytool_remove_backend $fid

	$LFS hsm_restore $f
	wait_request_state $fid RESTORE FAILED
	local st=$?

	# cleanup
	cdt_clear_no_retry

	# Test result
	[[ $st == 0 ]] || error "Restore does not failed"

	copytool_cleanup
}
run_test 111a "No retry policy (import case), restore will error"\
	      " (No such file or directory)"

test_111b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)
	cdt_set_no_retry
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	copytool_remove_backend $fid

	$LFS hsm_restore $f
	wait_request_state $fid RESTORE FAILED
	local st=$?

	# cleanup
	cdt_clear_no_retry

	# Test result
	[[ $st == 0 ]] || error "Restore does not failed"

	copytool_cleanup
}
run_test 111b "No retry policy (release case), restore will error"\
	      " (No such file or directory)"

test_112() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)
	cdt_disable
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	local l=$($LFS hsm_action $f)
	echo $l
	local res=$(echo $l | cut -f 2- -d" " | grep ARCHIVE)

	# cleanup
	cdt_enable
	wait_request_state $fid ARCHIVE SUCCEED

	# Test result
	[[ ! -z "$res" ]] || error "action is $l which is not an ARCHIVE"

	copytool_cleanup
}
run_test 112 "State of recorded request"

test_200() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_cancel $f)
	# test with cdt on is made in test_221
	cdt_disable
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	$LFS hsm_cancel $f
	cdt_enable
	wait_request_state $fid ARCHIVE CANCELED
	wait_request_state $fid CANCEL SUCCEED

	copytool_cleanup
}
run_test 200 "Register/Cancel archive"

test_201() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	make_archive $tdir/$tfile
	import_file $tdir/$tfile $f
	local fid=$(path2fid $f)

	# test with cdt on is made in test_222
	cdt_disable
	$LFS hsm_restore $f
	$LFS hsm_cancel $f
	cdt_enable
	wait_request_state $fid RESTORE CANCELED
	wait_request_state $fid CANCEL SUCCEED

	copytool_cleanup
}
run_test 201 "Register/Cancel restore"

test_202() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED

	cdt_disable
	$LFS hsm_remove $f
	$LFS hsm_cancel $f
	cdt_enable
	wait_request_state $fid REMOVE CANCELED

	copytool_cleanup
}
run_test 202 "Register/Cancel remove"

test_220() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)

	changelog_setup

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED

	local flags=$(changelog_get_flags $MDT0 HSM $fid | tail -1)
	changelog_cleanup

	local target=0x0
	[[ $flags == $target ]] || error "Changelog flag is $flags not $target"

	copytool_cleanup
}
run_test 220 "Changelog for archive"

test_221() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_cancel $f)

	changelog_setup

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE STARTED
	$LFS hsm_cancel $f
	wait_request_state $fid ARCHIVE CANCELED
	wait_request_state $fid CANCEL SUCCEED

	local flags=$(changelog_get_flags $MDT0 HSM $fid | tail -1)

	local target=0x7d
	[[ $flags == $target ]] || error "Changelog flag is $flags not $target"

	changelog_cleanup
	copytool_cleanup
}
run_test 221 "Changelog for archive canceled"

test_222a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir $HSM_ARCHIVE/$tdir
	local f=$DIR/$tdir/$tfile
	cp /etc/passwd $HSM_ARCHIVE/$tdir/$tfile
	import_file $tdir/$tfile $f
	local fid=$(path2fid $f)

	changelog_setup

	$LFS hsm_restore $f
	wait_request_state $fid RESTORE SUCCEED

	local flags=$(changelog_get_flags $MDT0 HSM $fid | tail -1)

	local target=0x80
	[[ $flags == $target ]] || error "Changelog flag is $flags not $target"

	changelog_cleanup
	copytool_cleanup
}
run_test 222a "Changelog for explicit restore"

test_222b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)

	changelog_setup
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f

	md5sum $f

	wait_request_state $fid RESTORE SUCCEED

	local flags=$(changelog_get_flags $MDT0 HSM $fid | tail -1)

	local target=0x80
	[[ $flags == $target ]] || error "Changelog flag is $flags not $target"

	changelog_cleanup
	copytool_cleanup
}
run_test 222b "Changelog for implicit restore"

test_223a() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	make_archive $tdir/$tfile

	changelog_setup

	import_file $tdir/$tfile $f
	local fid=$(path2fid $f)

	$LFS hsm_restore $f
	wait_request_state $fid RESTORE STARTED
	$LFS hsm_cancel $f
	wait_request_state $fid RESTORE CANCELED
	wait_request_state $fid CANCEL SUCCEED

	local flags=$(changelog_get_flags $MDT0 HSM $fid | tail -1)

	local target=0xfd
	[[ $flags == $target ]] ||
		error "Changelog flag is $flags not $target"

	changelog_cleanup
	copytool_cleanup
}
run_test 223a "Changelog for restore canceled (import case)"

test_223b() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)

	changelog_setup
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	$LFS hsm_release $f
	$LFS hsm_restore $f
	wait_request_state $fid RESTORE STARTED
	$LFS hsm_cancel $f
	wait_request_state $fid RESTORE CANCELED
	wait_request_state $fid CANCEL SUCCEED

	local flags=$(changelog_get_flags $MDT0 HSM $fid | tail -1)

	local target=0xfd
	[[ $flags == $target ]] ||
		error "Changelog flag is $flags not $target"

	changelog_cleanup
	copytool_cleanup
}
run_test 223b "Changelog for restore canceled (release case)"

test_224() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f=$DIR/$tdir/$tfile
	local fid=$(copy_file /etc/passwd $f)

	changelog_setup
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED

	$LFS hsm_remove $f
	wait_request_state $fid REMOVE SUCCEED

	local flags=$(changelog_get_flags $MDT0 HSM $fid | tail -1)

	local target=0x200
	[[ $flags == $target ]] ||
		error "Changelog flag is $flags not $target"

	changelog_cleanup
	copytool_cleanup
}
run_test 224 "Changelog for remove"

test_225() {
	# test needs a running copytool
	copytool_setup

	# test is not usable because remove request is too fast
	# so it is always finished before cancel can be done ...
	echo "Test disabled"
	copytool_cleanup
	return 0

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_progress $f)

	changelog_setup
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED

	# if cdt is on, it can serve too quickly the request
	cdt_disable
	$LFS hsm_remove $f
	$LFS hsm_cancel $f
	cdt_enable
	wait_request_state $fid REMOVE CANCELED
	wait_request_state $fid CANCEL SUCCEED

	flags=$(changelog_get_flags $MDT0 RENME $fid2)
	local flags=$($LFS changelog $MDT0 | grep HSM | grep $fid | tail -1 |
		awk '{print $5}')

	local target=0x27d
	[[ $flags == $target ]] ||
		error "Changelog flag is $flags not $target"

	changelog_cleanup
	copytool_cleanup
}
run_test 225 "Changelog for remove canceled"

test_226() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir

	local f1=$DIR/$tdir/$tfile-1
	local f2=$DIR/$tdir/$tfile-2
	local f3=$DIR/$tdir/$tfile-3
	local fid1=$(copy_file /etc/passwd $f1)
	local fid2=$(copy_file /etc/passwd $f2)
	copy_file /etc/passwd $f3

	changelog_setup
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f1
	wait_request_state $fid1 ARCHIVE SUCCEED

	$LFS hsm_archive $f2
	wait_request_state $fid2 ARCHIVE SUCCEED

	rm $f1 || error "rm $f1 failed"

	local flags=$(changelog_get_flags $MDT0 UNLNK $fid1)

	local target=0x3
	[[ $flags == $target ]] ||
		error "Changelog flag is $flags not $target"

	mv $f3 $f2 || error "mv $f3 $f2 failed"

	flags=$(changelog_get_flags $MDT0 RENME $fid2)

	target=0x3
	[[ $flags == $target ]] ||
		error "Changelog flag is $flags not $target"

	changelog_cleanup
	copytool_cleanup
}
run_test 226 "changelog for last rm/mv with exiting archive"

check_flags_changes() {
	local f=$1
	local fid=$2
	local hsm_flag=$3
	local fst=$4
	local cnt=$5

	local target=0x280
	$LFS hsm_set --$hsm_flag $f ||
		error "Cannot set $hsm_flag on $f"
	local flags=($(changelog_get_flags $MDT0 HSM $fid))
	local seen=${#flags[*]}
	cnt=$((fst + cnt))
	[[ $seen == $cnt ]] ||
		error "set $hsm_flag: Changelog events $seen != $cnt"
	[[ ${flags[$((cnt - 1))]} == $target ]] ||
		error "set $hsm_flag: Changelog flags are "\
			"${flags[$((cnt - 1))]} not $target"

	$LFS hsm_clear --$hsm_flag $f ||
		error "Cannot clear $hsm_flag on $f"
	flags=($(changelog_get_flags $MDT0 HSM $fid))
	seen=${#flags[*]}
	cnt=$(($cnt + 1))
	[[ $cnt == $seen ]] ||
		error "clear $hsm_flag: Changelog events $seen != $cnt"

	[[ ${flags[$((cnt - 1))]} == $target ]] ||
		error "clear $hsm_flag: Changelog flag is "\
			"${flags[$((cnt - 1))]} not $target"
}

test_227() {
	# test needs a running copytool
	copytool_setup
	changelog_setup

	mkdir -p $DIR/$tdir
	typeset -a flags

	for i in norelease noarchive exists archived
	do
		local f=$DIR/$tdir/$tfile-$i
		local fid=$(copy_file /etc/passwd $f)
		check_flags_changes $f $fid $i 0 1
	done

	f=$DIR/$tdir/$tfile---lost
	fid=$(copy_file /etc/passwd $f)
	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE SUCCEED
	check_flags_changes $f $fid lost 3 1

	changelog_cleanup
	copytool_cleanup
}
run_test 227 "changelog when explicit setting of HSM flags"

test_250() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local maxrequest=$(get_hsm_param max_requests)
	local rqcnt=$(($maxrequest * 3))
	local i=""

	cdt_disable
	for i in $(seq -w 1 $rqcnt); do
		rm -f $DIR/$tdir/$i
		dd if=/dev/urandom of=$DIR/$tdir/$i bs=1M count=10 conv=fsync
	done
	# we do it in 2 steps, so all requests arrive at the same time
	for i in $(seq -w 1 $rqcnt); do
		$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $DIR/$tdir/$i
	done
	cdt_enable
	local cnt=$rqcnt
	local wt=$rqcnt
	while [[ $cnt != 0 || $wt != 0 ]]; do
		sleep 1
		cnt=$(do_facet $SINGLEMDS "$LCTL get_param -n\
			$HSM_PARAM.agent_actions |\
			grep STARTED | grep -v CANCEL | wc -l")
		[[ $cnt -le $maxrequest ]] ||
			error "$cnt > $maxrequest too many started requests"
		wt=$(do_facet $SINGLEMDS "$LCTL get_param\
			$HSM_PARAM.agent_actions |\
			grep WAITING | wc -l")
		echo "max=$maxrequest started=$cnt waiting=$wt"
	done

	copytool_cleanup
}
run_test 250 "Coordinator max request"

test_251() {
	# test needs a running copytool
	copytool_setup

	mkdir -p $DIR/$tdir
	local f=$DIR/$tdir/$tfile
	local fid=$(make_large_for_cancel $f)

	cdt_disable
	# to have a short test
	local old_to=$(get_hsm_param request_timeout)
	set_hsm_param request_timeout 4
	# to be sure the cdt will wake up frequently so
	# it will be able to cancel the "old" request
	local old_loop=$(get_hsm_param loop_period)
	set_hsm_param loop_period 2
	cdt_enable

	$LFS hsm_archive --archive $HSM_ARCHIVE_NUMBER $f
	wait_request_state $fid ARCHIVE STARTED
	sleep 5
	wait_request_state $fid ARCHIVE CANCELED

	set_hsm_param request_timeout $old_to
	set_hsm_param loop_period $old_loop

	copytool_cleanup
}
run_test 251 "Coordinator request timeout"

test_300() {
	# the only way to test ondisk conf is to restart MDS ...
	echo "Stop coordinator and remove coordinator state at mount"
	# stop coordinator
	cdt_shutdown
	# clean on disk conf set by default
	cdt_clear_mount_state
	cdt_check_state stopped

	# check cdt still off after umount/remount
	fail $SINGLEMDS
	cdt_check_state stopped

	echo "Set coordinator start at mount, and start coordinator"
	cdt_set_mount_state enabled

	# check cdt is on
	cdt_check_state enabled

	# check cdt still on after umount/remount
	fail $SINGLEMDS
	cdt_check_state enabled

	# we are back to original state (cdt started at mount)
}
run_test 300 "On disk coordinator state kept between MDT umount/mount"

copytool_cleanup

complete $SECONDS
check_and_cleanup_lustre
exit_status
