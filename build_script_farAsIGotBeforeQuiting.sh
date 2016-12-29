#!/bin/ksh
#Author: T. Hays
#This script automates the process of building release sets for OpenBSD.
#Place the following in roots .kshrc, and be sure to use "su -" to escalate privs on reboot
#
# If rc.build exists, run it just once, and make sure it is deleted
# if [ -f /etc/rc.build ]; then
#         mv /etc/rc.build /etc/rc.build.run
#         /bin/ksh /etc/rc.build.run 2>&1 | tee /dev/tty |
#                 mail -Es "`hostname` rc.build output" root >/dev/null
# rm -f /etc/rc.build.run
# fi

## TODO: Yes, I know about paramater expansion. I'll work on making this
##			script a little more safe "sometime in the future" :)
##			
set -e
set -x
renice -n 19 $$ >/dev/null 2>&1

#Save stdin and stderr; we need them later
exec 8>&1
exec 9>&2

# Refuse to run unless we're root
# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" 1>&2
        exit 1
fi

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/X11R6/bin

# Uncomment this to set a different script to run after boot.
_afterbootscript="$(readlink -f -- $0)"

#Obj directories
_objdir=/usr/obj
_xobjdir=/usr/xobj

# Directory to hold the logs after building
_bld=/var/log/buildlogs

#Log files for repective build processes
_blk=${_bld}/logfile_kernel_build
_blu=${_bld}/logfile_userland_build
_blr=${_bld}/logfile_release_build
_blx=${_bld}/logfile_xenocara_build
_blxr=${_bld}/logfile_xenocara_release_build

#Directories for release building
DESTDIR=/home/toad/dest
RELEASEDIR=/home/toad/rel

# Directory to contain the final file sets, arranged similarly to the
# OpenBSD CD.
_imgroot=/home/toad/OpenBSD

_isoimage=${RELEASEDIR}/soekrisinstaller.iso
_isodir=${RELEASEDIR}/soekrisinstaller
_isserial=0
_webroot=/var/www/htdocs/pub/OpenBSD

#Location of signify key, if one exists
_sigkeyname=fg-amd64
_sigkeysec=/etc/signify/${_sigkeyname}.sec
_sigkeypub=/etc/signify/${_sigkeyname}.pub


#Location of source directory
_srcdir=/usr/src

#The architecture of the build machine
_archy=$(machine)

#The release version of the running system
_version=$(uname -r)

# Build the MP processor if we have more than one core
CORES=$(sysctl hw.ncpufound)
CORES=${CORES#*=}
if [[ -z ${NAME} ]]; then
        if [[ ${CORES} > 1 ]]; then
                NAME=GENERIC.MP
        else
                NAME=GENERIC
        fi
fi

#Define functions
function bakdir {
    if [[ -d "$1" ]]; then
        [[ -d "${1}.previous" ]] && rm -r "${1}.previous"
        cp -R "$1" "${1}.previous"
    fi
}

function rmdirsafe {
    if  [[ -d $1 ]]; then
        mv "$1" "${1}.old"
        rm -rf "${1}.old" &
    fi
        mkdir -p "$1"
   
}

function rmlogsafe {
    local _tl _td

    if ! _tl=$(mktemp -d); then
        print -u2 Error: Cannot create temp directory
        exit 1
    fi
   
    if ! [[ -d $1 ]]; then
        print -u2 Error: "$1" is not a directory or does not exist
        exit 1
    else
        _td="${1##*/}" 
        cp -r "$1" "$_tl"
        umount "$1"
        bakdir "$1"
        [[ -z "$(ls -A "$1")" ]] || rm -r "$1"/*
        mv "$_tl/$_td" "${1%/*}" 
        rm  -r "$_tl"
    fi
}

function fdredir {
    _fifo="/tmp/tmp.${RANDOM}"
    mkfifo "${_fifo}"
    touch "$1"
    tee -a "$1" < "${_fifo}" &
    exec > "${_fifo}" 2>&1
}

function mkiso {
	if [[ ! -d "$DESTDIR" ]]; then
		  print -u2 "Error: The specified directory does not exist"
		  exit 1
	  else
		  cd ${RELEASEDIR}
		  [[ ! -d "${_isodir}" ]] && rmdirsafe "${_isodir}"
		  dd if=/dev/zero of="$_isoimage" bs=1m count=200
	fi
                
	if [ : ]; then 
		  vnconfig -l|grep "not in use" >/dev/null 2>&1 
		  _isaval=$? 
	fi
                
	if [[ "$_isaval" != 0 ]]; then
		  print -u2 "Error: There are no free vnodes available"
	  else
		  _vnddev=$(vnconfig -l|grep "not in use"|head -n1|cut -d : -f 1)
	fi
		  vnconfig -c "$_vnddev" "$_isoimage"
		  fdisk -iy "$_vnddev"
		  disklabel -Aw "$_vnddev"
		  newfs -O 1 "${_vnddev}a"
		  mount /dev/"${_vnddev}a" "$_isodir"
		 # [[ -d "$_isodir" ]] && cp -p ${_imgroot}/${_version}/${_archy}/bsd.rd "$_isodir"
		  [[ -d "$_isodir" ]] && cp -p ${RELEASEDIR}/bsd.rd "$_isodir"
		  
		  if [[ "$_isserial" = 0 ]]; then
			[[ -d "$_isodir" ]] && cp -Rp ${_imgroot}/etc "$_isodir"
		  fi
		  
		  installboot -v -r "$_isodir" vnd0 /usr/mdec/biosboot /usr/mdec/boot
		  umount "$_isodir"
          vnconfig -u "$_vnddev"
          rm -r "$_isodir"
}

#This function was taken from src/distrib/miniroot/install.sub
function askpass {
        stty -echo
        IFS= read -r resp?"$1 "
        stty echo
        echo
}

#This function was taken from src/distrib/miniroot/install.sub
function askpassword {
        _q="Provide the signify password: "
        while :; do
                askpass "$_q (will not echo)"
                _password=$resp
                askpass "$_q (again)"
                [[ $resp == "$_password" ]] && break
                echo "Passwords do not match, try again."
        done
}
#End function definitions
 
#TODO: Add check to see if only seckey is non-existent
#       If so delete pubkey and create pair again 
#		Way to force a unique, unused password? INORITE
# Create signing keys if none exist
if [[ ! -f "${_sigkeypub}" || ! -f "${_sigkeysec}" ]]; then
        echo -e "Creating signify key:\n"
        signify -G -p "${_sigkeypub}" -s "${_sigkeysec}"
fi

# Use tmpfs(4) during the build process
[[ ! -d ${_bld} ]] && rmdirsafe ${_bld}
[[ ! -d ${_objdir} ]] && rmdirsafe ${_objdir}
mount -t tmpfs tmpfs ${_bld}
mount -t tmpfs tmpfs ${_objdir}

#### 1. BUILD AND INSTALL A NEW KERNEL
##############################################
fdredir "${_blk}" #Log Kernel build
if [[ -z $1 || X$1 != X"-r" ]]; then # Separate out the non-post-reboot code

        # Build the new kernel
        echo -e "$(date)"
        echo -e "Starting new kernel build...\n"
        cd /usr/src/sys/arch/${_archy}/conf
        config ${NAME}
        cd /usr/src/sys/arch/${_archy}/compile/${NAME}
        make clean
        make -j${CORES}
        make install

        # Queue this script to run the rest after reboot
        echo "$_afterbootscript -r"
        echo "$_afterbootscript -r" >> /etc/rc.build
        echo -e "New Kernel built!\nCopying kernel build log out of ramisk, and rebooting..."
        cp ${_blk} /var/log # Copy the build log out of the ramdisk
        shutdown -r now "New kernel built, rebooting."
        exit
fi
# Retreive the kernel build logs after reboot
mv /var/log/${_blk##*/} ${_bld}

#### 2. BUILD AND INSTALL SYSTEM 
##############################################
fdredir "${_blu}"   #Log Userland build
rm -rf ${_objdir}/* #Remove old object files

# Build the new userland
cd /usr/src
echo "Making userland obj..."
make obj
cd /usr/src/etc
echo "Making userland distrib-dirs..."
env DESTDIR=/ make distrib-dirs
cd /usr/src
echo "Building userland..."
make build 

#### 3. MAKE THE SYSTEM RELEASE AND VALIDATE
##############################################
fdredir "${_blr}" #Log Release build
echo "Starting release build..."
export DESTDIR
export RELEASEDIR

# Safely remove old $DESTDIR in the background, and make working directories
rmdirsafe ${DESTDIR}
mkdir -p ${DESTDIR} ${RELEASEDIR}  

# Build the sets
cd /usr/src/etc
make release
cd /usr/src/distrib/sets
sh checkflist
cd ${RELEASEDIR}

#### 4. BUILD AND INSTALL XENOCARA 
##############################################
fdredir "${_blx}" #Log Xenocara build
rmdirsafe ${_xobjdir} 

# Build xenocara
cd /usr/xenocara
export PATH
make bootstrap
make obj
make build

#### 5. MAKE THE XENOCARA RELEASE AND VALIDATE
##############################################
fdredir "${_blxr}" #Log Xenocara release build
rmdirsafe ${DESTDIR}
cd /usr/xenocara 
make release 


#### 6. ORGANIZE TO RELEASE STRUCTURE
##############################################
bakdir $_imgroot
rmdirsafe $_imgroot

# Create a boot.conf file
if [[ "$_isserial" = 0 ]]; then
	#[[ -d "$_imgroot" ]] && mkdir -p ${_imgroot}/etc
	[[ -d "${_imgroot}/etc" ]] || mkdir -p ${_imgroot}/etc
	echo "stty com0 19200" > ${_imgroot}/etc/boot.conf
	echo "set tty com0" >> ${_imgroot}/etc/boot.conf
	#echo "set image /5.6/amd64/bsd.rd" >>  ${_imgroot}/etc/boot.conf
fi

# Create installer iso
mkiso

mkdir -p ${_imgroot}/${_version}
cp -Rp ${RELEASEDIR}/ ${_imgroot}/${_version}/${_archy}

# Add the updated source code and the build logs, too
cd ${_imgroot}/${_version}/${_archy}
tar zcf src_stable_errata.tar.gz /usr/src
tar zcf xenocara_stable_errata.tar.gz /usr/xenocara
tar zcf ports_stable.tar.gz /usr/ports
tar zcf buildlogs.tar.gz ${_bld}/


#### 7. SIGN ALL SETS USING OUR OWN KEY
##############################################
cd ${_imgroot}/${_version}/${_archy}
rm SHA256
cksum -a SHA256 * > SHA256
askpassword
echo $_password | signify -S -e -s ${_sigkeysec} -m SHA256 -x SHA256.sig

ls -ln > index.txt

rmdirsafe $_webroot
cp -Rp ${_imgroot}/* $_webroot


rm ${_sigkeysec}

# clean up.
##############################################
exec 1>&8
exec 2>&9
rm /tmp/tmp.[0-9]*
rmlogsafe ${_bld}
umount ${_objdir}
unset RELEASEDIR
unset DESTDIR
unset PATH
