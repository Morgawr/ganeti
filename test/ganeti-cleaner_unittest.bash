#!/bin/bash
#

# Copyright (C) 2010 Google Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.

set -e
set -o pipefail

export PYTHON=${PYTHON:=python}

GNTC=daemons/ganeti-cleaner
CCE=tools/check-cert-expired

err() {
  echo "$@"
  echo 'Aborting'
  exit 1
}

upto() {
  echo "$(date '+%F %T'):" "$@" '...'
}

gencert() {
  local path=$1 validity=$2
  VALIDITY=$validity $PYTHON \
    ${TOP_SRCDIR:-.}/test/import-export_unittest-helper \
    $path gencert
}

check_logfiles() {
  local n=$1
  [[ "$(find $tmpls/log/ganeti/cleaner -mindepth 1 | wc -l)" -le "$n" ]] || \
    err "Found more than $n logfiles"
}

count_jobs() {
  local n=$1
  local count=$(find $queuedir -mindepth 1 -type f | wc -l)
  [[ "$count" -eq "$n" ]] || err "Found $count jobs instead of $n"
}

count_watcher() {
  local n=$1
  local count=$(find $watcherdir -maxdepth 1 -type f \
                  -name 'watcher.*.data' | wc -l)
  [[ "$count" -eq "$n" ]] || err "Found $count watcher files instead of $n"
}

count_and_check_certs() {
  local n=$1
  local count=$(find $cryptodir -mindepth 1 -type f -name cert | wc -l)
  [[ "$count" -eq "$n" ]] || err "Found $count certificates instead of $n"

  find $cryptodir -mindepth 1 -type d | \
  while read dir; do
    [[ ( -e $dir/key && -e $dir/cert ) ||
       ( ! -e $dir/cert && ! -e $dir/key ) ]] || \
      err 'Inconsistent cert/key directory found'
  done
}

run_cleaner() {
  CHECK_CERT_EXPIRED=$CCE LOCALSTATEDIR=$tmpls $GNTC
}

create_archived_jobs() {
  local i jobdir touchargs
  local jobarchive=$queuedir/archive
  local old_ts=$(date -d '25 days ago' +%Y%m%d%H%M)

  # Remove jobs from previous run
  find $jobarchive -mindepth 1 -type f | xargs -r rm

  i=0
  for job_id in {1..50} 469581574 19857 1420164 494433 2448521
  do
    jobdir=$jobarchive/$(( job_id / 10 ))
    test -d $jobdir || mkdir $jobdir

    if (( i % 3 == 0 || i % 7 == 0 )); then
      touchargs="-t $old_ts"
    else
      touchargs=
    fi
    touch $touchargs $jobdir/job-$job_id

    let ++i
  done
}

create_watcher_state() {
  local uuids=(
    6792a0d5-f8b6-4531-8d8c-3680c86b8a53
    ab74da37-f5f7-44c4-83ad-074159772593
    fced2e48-ffff-43ae-919e-2b77d37ecafa
    6e89ac57-2eb1-4a16-85a1-94daa815d643
    8714e8f5-59c4-47db-b2cb-196ec37978e5
    91763d73-e1f3-47c7-a735-57025d4e2a7d
    e27d3ff8-9546-4e86-86a4-04151223e140
    aa3f63dd-be17-4ac8-bd01-d71790e124cb
    05b6d7e2-003b-40d9-a6d6-ab61bf123a15
    54c93e4c-61fe-40de-b47e-2a8e6c805d02
    )

  i=0
  for uuid in ${uuids[@]}; do
    touch -d "$(( 5 * i )) days ago" $watcherdir/watcher.$uuid.data

    let ++i
  done
}

create_certdirs() {
  local cert=$1; shift
  local certdir
  for name in "$@"; do
    certdir=$cryptodir/$name
    mkdir $certdir
    if [[ -n "$cert" ]]; then
      cp $cert $certdir/cert
      cp $cert $certdir/key
    fi
  done
}

tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

# Temporary localstatedir
tmpls=$tmpdir/var
queuedir=$tmpls/lib/ganeti/queue
cryptodir=$tmpls/run/ganeti/crypto
watcherdir=$tmpls/lib/ganeti

mkdir -p $tmpls/{lib,log,run}/ganeti $queuedir/archive $cryptodir

maxlog=50

upto 'Checking log directory creation'
test -d $tmpls/log/ganeti || err 'log/ganeti does not exist'
test -d $tmpls/log/ganeti/cleaner && \
  err 'log/ganeti/cleaner should not exist yet'
run_cleaner
test -d $tmpls/log/ganeti/cleaner || err 'log/ganeti/cleaner should exist'
check_logfiles 1

upto 'Checking number of retained log files'
for (( i=0; i < (maxlog + 10); ++i )); do
  run_cleaner
  check_logfiles $(( (i + 2) > $maxlog?$maxlog:(i + 2) ))
done

upto 'Removal of archived jobs (non-master)'
create_archived_jobs
count_jobs 55
test -f $tmpls/lib/ganeti/ssconf_master_node && \
  err 'ssconf_master_node should not exist'
run_cleaner
count_jobs 55

upto 'Removal of archived jobs (master node)'
create_archived_jobs
count_jobs 55
echo $HOSTNAME > $tmpls/lib/ganeti/ssconf_master_node
run_cleaner
count_jobs 31

upto 'Certificate expiration'
gencert $tmpdir/validcert 30 & vcpid=${!}
gencert $tmpdir/expcert -30 & ecpid=${!}
wait $vcpid $ecpid
create_certdirs $tmpdir/validcert foo{a,b,c}123 trvRMH4Wvt OfDlh6Pc2n
create_certdirs $tmpdir/expcert bar{x,y,z}999 fx0ljoImWr em3RBC0U8c
create_certdirs '' empty{1,2,3} gd2HCvRc iFG55Z0a PP28v5kg
count_and_check_certs 10
run_cleaner
count_and_check_certs 5

check_logfiles $maxlog
count_jobs 31

upto 'Watcher status files'
create_watcher_state
count_watcher 10
run_cleaner
count_watcher 5

exit 0
