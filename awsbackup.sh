#!/usr/bin/env bash
#
# ./awsbackup.sh - personal backup with AWS S3 Glacier Deep Archive
#
# written by Klaus Eisentraut, May 2019
#
# This work is free. It comes without any warranty, to the extent permissible
# by applicable law. You can redistribute it and/or modify it under the
# terms of the Do What The Fuck You Want To Public License, Version 2,
# as published by Sam Hocevar. See http://www.wtfpl.net/ for more details.
#


# -----------------------------------------------------------------------------
# TODO: adjust everything below for your personal needs
PASSWORD_LOCATION='/tmp/backup-password'  # for convenience, encryption password can be (temporarily) stored in a file.
ITERATIONS=1000000                        # number of PBKDF2 iterations
BUCKET="my-bucket"                        # name of aws bucket 
LOCAL="/mnt/backup"                       # path to directory where local copy of archives is stored
FOLDER="awsbackup"                        # name of subfolder in bucket and local folder, this is where the actual data goes
MULTIPART_CHUNKSIZE=$((8*1024*1024))      # must be identical with your AWS settings! Default is 8MiB for both settings.
MULTIPART_THRESHOLD=$((8*1024*1024))
STORAGE_CLASS="DEEP_ARCHIVE"              # AWS S3 storage class, DEEP_ARCHIVE is the cheapest for long-term archiving 
# We need to catch wrong passwords because a backup with a wrong encryption password is useless.
# For initial setup, run
#     echo "backupsalt" | openssl enc -e -nosalt -aes-256-cbc -pbkdf2 -iter "$ITERATIONS" -pass pass:"$pass" | xxd -p 
# and copy 4 hexadecimal characters out of it (can be copied from inside the middle, too).
# This will catch 1-(1-1/16**4)**(32-4) > 99.9% of the wrong passwords while not giving any advantage for a brute-force attack.
PASSWORD_HASH='b4e4' 
# TODO: adjust everything above
# -----------------------------------------------------------------------------

# fail on all errors, do not change!
set -e 

# This helper function reads the password either from a file, or from stdin.
function getPassword {
    if [ -f "$PASSWORD_LOCATION" ]; then
        pass=$(cat "$PASSWORD_LOCATION")
    else
        echo -n "Enter password: "
        read pass
    fi
    # check password
        echo "FATAL ERROR: Password wrong, exit."
    if [[ ! $(echo "backupsalt" | openssl enc -e -nosalt -aes-256-cbc -pbkdf2 -iter "$ITERATIONS" -pass pass:"$pass" | xxd -p ) =~ "$PASSWORD_HASH" ]]; then
        exit 1
    fi
}

# en/decrypt a filename deterministically into a URL-safe string
# please be aware that we use CBC mode here, CTR mode with no-salt would be very dangerous!
function encryptString {
    echo -n "$1" | openssl enc -e -nosalt -aes-256-cbc -pbkdf2 -iter "$ITERATIONS" -pass pass:"$pass" -a -A | tr '/+' '_-'
}
function decryptString {
    echo -n "$1" | tr '_-' '/+' | openssl enc -d -nosalt -aes-256-cbc -pbkdf2 -iter "$ITERATIONS" -pass pass:"$pass" -a -A 
}

# check local archives for bitrot by calculating SHA256 sum and 
# comparing against SHA256 hash calculated during creation
function localVerify {
    echo "local verification has started, please be patient"
    cd "$LOCAL"/ >/dev/null
    sha256sum -c --quiet SHA256.txt
    cd - >/dev/null
    # sha256sum will have aborted this script otherwise (set -e)
    echo "SUCCESS: local verification did not detect errors"
}

# calculate AWS S3 etag, see https://stackoverflow.com/a/19896823
function etagHash {
    filename="$1"
    if [[ ! -f "$filename" ]]; then echo "FATAL ERROR: wrong usage of etagHash"; exit 1; fi
    size=$(du -b "$filename" | cut -f1)
    if [[ "$size" -lt "$MULTIPART_THRESHOLD" ]]; then
        # etag is simply the md5sum
        md5sum "$filename" | cut -d ' ' -f 1
    else
        # etag is MD5 of MD5s, see https://stackoverflow.com/a/19896823
        part=0
        offset=0
        tmp=$(mktemp /tmp/awsbackup.XXXXXXX)
        while [[ "$offset" -lt "$size" ]]; do
            dd if="$filename" bs="$MULTIPART_CHUNKSIZE" skip="$part" count=1 2>/dev/null | md5sum | cut --bytes=-32 | tr -d '\n' >> "$tmp"
            part=$(( "$part" + 1))
            offset=$(( "$part"*"$MULTIPART_CHUNKSIZE" ))
        done
        echo $(xxd -r -p "$tmp" | md5sum | cut --bytes=-32)-"$part"
        rm -f "$tmp"
    fi
}

function add {
    # check if folder exists
    if [ ! -d "$1" ]; then
        echo "FATAL ERROR: Directory '$1' does not exist and can not get archived!" 
        exit 1
    fi
    # check if name has format YYYY-MM-DD_alphanumeric_description
    if [[ ! "$2" =~ [12][0-9X][0-9X]{2}-[01X][0-9X]-[0-3X][0-9X]_[a-zA-Z_\-]+ ]]; then
        echo "FATAL ERROR: Name '$2' is invalid! Only names which have a format like 2001-12-2X_Christmas_Vacation are accepted."
        exit 1
    fi
    # check, if archive already exists
    if [[ -f "$LOCAL"/"$2".tar.xz.enc ]]; then
        echo "FATAL ERROR: Archive "$2" already exists!"
        exit 1
    fi

    # get encryption password
    getPassword
    
    # tar, compress, encrypt, write and checksum archive 
    # workaround with temporary directory because file inside TAR archive must be named accordingly
    tmp=$(mktemp -d /tmp/awsbackup.tmp.folder.XXXXXXXX)
    ln -s "$(pwd)"/"$1" "$tmp"/"$2"
    cd "$tmp" 
    sha2=$(tar cvh "$2" | xz -9e -C sha256 | openssl enc -e -salt -aes-256-ctr -pbkdf2 -iter "$ITERATIONS" -pass pass:"$pass" | tee "$LOCAL/$FOLDER/$2.tar.xz.enc" | sha256sum | cut --bytes=-64)
    unlink "$tmp"/"$2"
    rmdir "$tmp"
    cd - >/dev/null

    # add to inventory
    etag=$(etagHash "$LOCAL/$FOLDER/$2.tar.xz.enc")
    echo -e "$etag  ./$FOLDER/$2.tar.xz.enc" >> "$LOCAL"/ETAGS.txt
    echo -e "$sha2  ./$FOLDER/$2.tar.xz.enc" >> "$LOCAL"/SHA256.txt

    # display success
    echo "SUCCESS: Created local copy. Please run \"cloud-sync\" command now."
}
# This function does
#   - upload local archives which are not already stored in the cloud
#   - warn, if there are any files in the cloud where we do not have a local copy
function cloudsync {
    aws s3api list-objects --bucket "$BUCKET" > "$LOCAL"/list-objects.txt
    getPassword
    cat "$LOCAL"/ETAGS.txt | while read etag name; do
        if [[ ! "$etag" =~ ^([0-9a-f]{32,32})(-[0-9a-f]{1,5})?$ ]]; then echo "FATAL ERROR: etag $etag invalid!"; exit 1; fi
        if [[ ! -s "$LOCAL/$name" ]]; then echo "FATAL ERROR: file $LOCAL/$name invalid!"; exit 1; fi
        filename=$(basename "$name")
        encfilename=$(encryptString "$filename")
        etagAWS=$(cat "$LOCAL"/list-objects.txt | jq ".Contents[] | select(.Key|test(\"$FOLDER/$encfilename\")) | .ETag" | tr -d '"\\ ') 
        if [[ -z "$etagAWS" ]]; then
            echo "TODO: $filename is missing in cloud, will be uploaded."
            aws s3 cp --storage-class "$STORAGE_CLASS" "$LOCAL/$FOLDER/$filename" "s3://$BUCKET/$FOLDER/$encfilename"
        elif  [[ "$etag" == "$etagAWS" ]]; then
            echo "OK: $filename."
        else
            echo "FATAL ERROR: $filename is in cloud, but corrupt! Please check manually."
            exit 1
        fi
    done
    # now, check that we have an etag/SHA256 entry for every local file, too
    for i in "$LOCAL/$FOLDER/"*; do
        if ! grep -Fq $(basename "$i") "$LOCAL/ETAGS.txt"; then echo "FATAL ERROR: $i does not have an ETAG!"; exit 1; fi
        if ! grep -Fq $(basename "$i") "$LOCAL/SHA256.txt"; then echo "FATAL ERROR: $i does not have an SHA256!"; exit 1; fi
    done
    # now, check that every file in cloud exists locally, too.
    cat "$LOCAL"/list-objects.txt | jq ".Contents[] | select(.Key|test(\"$FOLDER/\")) | .ETag" | tr -d '"\\ ' | while read -r etag; do
        if ! grep -Fq "$etag" "$LOCAL/ETAGS.txt"; then echo "FATAL ERROR: Etag $etag exists in cloud, but not in local copy!"; exit 1; fi
    done

    echo "SUCCESS: Cloud and local files are in sync."
}


function localverify {
    cd "$LOCAL"/
    sha256sum -w -c SHA256.txt
    cd - >/dev/null
    echo "SUCCESS: All files in $LOCAL are ok!"
}

function usage {
    echo "./awsbackup.sh - Please use one of the following options:"
    echo ""
    echo "   add ./folder/to/be/backuped 1999-01-XX_Pictures_Vacation"
    echo "     - create compressed & encrypted archive out of folder on local computer"
    echo "     - you should run \"cloud-sync\" afterwards"
    echo "   cloud-sync"
    echo "     - upload local data to AWS S3 Glacier Deep Archive"
    echo "     - check for consistency and integrity between local copy & cloud"
    echo "   local-verify"
    echo "     - verify local data (no internet necessary)"
    echo "   store-password"
    echo "     - store password unsafe (!) until next reboot"
    echo "   remove-password"
    echo "     - remove stored password" 
    exit 1
}

case "$1" in
add) add "$2" "$3" ;;
local-verify) localverify ;;
cloud-sync) cloudsync;;
store-password) getPassword; echo "$pass" > "$PASSWORD_LOCATION" ;;
remove-password) rm -vf "$PASSWORD_LOCATION" ;;
*) usage ;;
esac


# overwrite password in memory before exiting
pass=01234567890123456789012345678901234567890123456789

# sync local files to disk
sync
