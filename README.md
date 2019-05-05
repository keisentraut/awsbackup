# awsbackup.sh

This is a bash script I use for storing my private picture collection at AWS S3 Deep Glacier.
I store around ~120GB of pictures (~550 archives) for only ~0.12 ct/month!

It was designed with the following criterias in mind:
* Uploaded archives never change, only new archives are added from time to time.
* Total number of archives is less than 10.000.
* No strange dependencies, should run on any Linux system.
* I have two local copies of all archives, AWS is only used for the off-site backup. AWS is only for the "My house burned to the ground."-scenarios.
* Bit-rot in local copies can be detected.
* File contents and file names are encrypted. Amazon cannot read any data of me.
* I use a >40 characters passphrase instead of a public/private key. This is not as convenient, but otherwise I would need to worry about losing the private key, too.
* It should be as simple as possible, restoring an archives should be possible without any scripts, too.

# How it works

Every local copy of the backup has the following file structure:
```
awsbackup/1999-02-17_Holiday.tar.xz.enc
awsbackup/2014-08-31_Wedding.tar.xz.enc
awsbackup/2017-09-01_Holiday_2.tar.xz.enc
awsbackup/...[many more]...
ETAGS.txt
SHA256.txt
awsbackup.sh
````
All actual content goes into the folder ```awsbackup```.
Additionally, some text files containing checksums are stored, too.
A new local copy can be made by simply copying all of the files above somewhere else.

Whenever I want to add a new archive with pictures, I copy them from my smartphone or camera to my laptop.
Let's assume the new pictures are stored in a folder called ```DCIM```.
Then I would run the command ```awsbackup.sh ~/DCIM/ 2019-05-02_Business_Trip``` which creates a new, xz-compressed, encrypted and checksummed archive. 
This is an offline operation which does not require internet.
I can delete the DCIM folder now, as I have one local, encrypted copy of it.

Afterwards I usually run ```awsbackup.sh cloud-sync``` which uploads all local archives which are not yet stored in the cloud.
It will warn for files which are stored in the cloud but I don't have a local copy, too.
The integrity of all files in AWS is checked by calculating the hash locally and comparing it to the one returned by AWS S3.

From time to time, I copy the local archives on my laptop to other local copies, for instance on an external HDD.
When I do this, I usually also run ```awsbackup.sh local-verify``` in the local copies which basically simply runs ```sha256sum -c SHA256.txt" in order to verify the integrity of the local files against the stored SHA256 hashes.

# Dependencies

You will usually need to install the following tools:

* xz
* openssl
* jq 
* aws-cli

Additional, the following trivial ones are likely already installed on your Linux system.

* bash
* md5sum
* sha256sum
* dd
* xxd
* cut
* tar

