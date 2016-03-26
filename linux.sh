#!/system/bin/bash

# Copyright (C) 2015  Kiva

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

#You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

###########################
#
# 通用 Linux ARM 加载器
#
###########################

# section("host_loader");
shopt -s expand_aliases

# 配置环境变量
bin="/system/bin"
bbox="busybox"
already_mount=false

export USER=root
export PATH=$bin:/usr/bin:/usr/local/bin:/usr/sbin:/bin:/usr/local/sbin:/usr/games:$PATH
export TERM=linux
export HOME=/root
export LD_PRELOAD=""

unset LOCPATH VIMRUNTIME LANG JAVA_HOME

# 临时文件夹
mytmpdir="/data/local/tmp/klinux.tmpdir"

# 分区或者镜像
device="/dev/block/vold/179:66"
# 分区格式
device_type="ext4"
# 挂载点
mnt="/data/local/linux"

sd0="/storage/sdcard0"
sd1="/storage/sdcard1"

# 启动的脚本
boot="/boot/krub.d/krub"
# 磁盘的分区表
disktab_suc="$mnt/boot/krub.d/etc/disk-table"
disktab_user="~/linux-disk"
disktab_tmp="$mytmpdir/disktab.$$.$RANDOM"

# 参数标志
nosd0=false
nosd1=false
noclear=false

wait_time=10
default_system_idx=0

# 多个系统
systems_title[0]="默认系统"
systems_root[0]="$mnt"
systems_index=1


SEC_LINUX="Linux"
SEC_DISK="Disk"

ITEM_DEVICE="Device"
ITEM_MNT="MountPoint"
ITEM_FSTYPE="FileSystem"


alias clear='if [[ "$noclear" != true ]];then command clear; fi'

function init_myself() {
  if [[ ! -d $mytmpdir ]];then
    $bbox mkdir -p -m 755 $mytmpdir
  fi
  
  $bbox rm -f $disktab_tmp &>/dev/null
  
  if [[ ! -d "$sd0" ]];then
    nosd0=true
  fi
  
  if [[ ! -d "$sd1" ]];then
    nosd1=true
  fi
}


# 如果 mnt 被修改，调用此函数
function update_var_depend_mnt() {
  disktab_suc=$mnt/boot/krub.d/etc/disk-table
  systems_root[0]="$mnt"
}



# 例子见: klinux-cfg-example.cfg
function klinux_parse_cfg() {
  local cfg="$1"
  
  if [[ ! -f "$cfg" ]];then
    return
  fi
  
  local linux_device=$(ini $cfg $SEC_LINUX $ITEM_DEVICE)
  if [[ "$linux_device"x != ""x ]];then
    device="$linux_device"
  fi
  
  linux_fstype="$(ini $cfg $SEC_LINUX $ITEM_FSTYPE)"
  if [[ "$linux_fstype"x != ""x ]];then
    device_type="$linux_fstype"
  fi
    
  linux_mnt="$(ini $cfg $SEC_LINUX $ITEM_MNT)"
  if [[ "$linux_mnt"x != ""x ]];then
    mnt="$linux_mnt"
    update_var_depend_mnt
  fi
  
  local index=0
  
  local ddevice
  for ddevice in $(ini $cfg $SEC_DISK $ITEM_DEVICE );do
    if [[ "$ddevice"x == ""x ]];then
      error_exit "$SEC_DISK[$index] $ITEM_DEVICE 不可为空."
    fi
    
    local sub=0
    
    # 找到挂载点
    local dmnt
    for dmnt in $(ini $cfg $SEC_DISK $ITEM_MNT);do
      if (( index == sub ));then
        break
      fi
      (( sub++ ))
    done
    if [[ "$dmnt"x == ""x ]];then
      dmnt="/mnt/Disk-$index"
    fi
    
    sub=0
    
    # 找到分区类型
    local dtype
    for dtype in $(ini $cfg $SEC_DISK $ITEM_FSTYPE);do
      if (( index == sub ));then
        break
      fi
      (( sub++ ))
    done
    if [[ "$dtype"x == ""x ]];then
      dtype="ext4"
    fi
    
    echo "${ddevice}::${dmnt}::${dtype}" >> $disktab_tmp
    
    (( index++ ))
  done
}



function klinux_create() {
  # -t 类型 ext{2,3,4}
  # -s 大小 M 为单位
  # -l 使用 loop
  # -d 使用分区
  # -p 路径 /dev/... 或者 xxx.img
  # -r 根文件系统
  # -b boot文件系统
  local opt="$($bbox getopt t:s:p:r:b:ld $@ 2>/dev/null)"
  
  local type="ext4"
  local size="100"
  local flag_loop=true
  local flag_device=false
  local path="/sdcard/kl.img"
  local roottar="/sdcard/KLinux-rootfs.tgz"
  
  eval set -- $opt
  
  while [[ ! -z "$1" ]];do
    case "$1" in
      "-t" ) 
        shift
        if [[ "$1"x == ""x ]];then
          error_exit "-t: 必须有一个参数被指定";
        fi
        if [[ "$1" == "ext2" || "$1" == "EXT2" ]];then
          type="ext2"
        elif [[ "$1" == "ext3" || "$1" == "EXT3" ]];then
          type="ext3"
        elif [[ "$1" == "ext4" || "$1" == "EXT4" ]];then
          type="ext4"
        else
          error_exit "不支持的分区: $1";
        fi 
        shift ;;
        
      "-s" )
        shift
        if [[ "$1"x == ""x ]];then
          error_exit "-s: 必须有一个参数被指定";
        fi
        local stmp="${1//[0-9]/}"
        if [[ "$stmp"x != ""x ]];then
          error_exit "-s: 参数必须是一个数字";
        fi
        size="$1"
        shift ;;
        
      "-l" )
        shift
        flag_loop=true
        flag_device=false ;;
        
      "-d" )
        shift
        flag_loop=false
        flag_device=true ;;
        
      "-p" )
        shift
        if [[ "$1"x == ""x ]];then
          error_exit "-p: 必须有一个参数被指定";
        fi
        path="$1"
        shift ;;
        
      "-r" )
        shift
        if [[ "$1"x == ""x ]];then
          error_exit "-r: 必须有一个参数被指定";
        fi
        if [[ ! -f "$1" ]];then
          error_exit "$1: 文件不存在";
        fi
        roottar="$1"
        shift ;;
        
      "--" ) 
        shift
        break ;;
    esac
    
  done
  
  #echo "-----------------> Debug"
  #echo "type : $type"
  #echo "size : $size"
  #echo "loop : $flag_loop"
  #echo "devi : $flag_device"
  #echo "path : $path"
  #echo "root : $roottar"
  #echo "-----------------> Debug"
  
  free_line
  echo -ne "读取系统信息... 0%\r"
  local fscmd="mkfs"
  local fsarg=""
  case "$type" in
    "ext4" )  fscmd="mkfs.ext4"
            fsarg="" ;;
    "ext3" )  fscmd="mke2fs"
            fsarg="-j -F" ;;
    "ext2" )  fscmd="mke2fs"
            fsarg="-F" ;;
  esac
  
  if [[ "$($bbox which $fscmd)"x == ""x ]];then
    echo
    error_exit "无法找到可以格式化 $type 文件系统的工具";
  fi
  
  free_line
  echo -ne "读取系统信息... 25%\r"
  if [[ -f /system/framework/framework-res.apk ]];then
    local tmnt="/data/local/tmp/.mylinux-$$"
    local log="/data/local/tmp/.mylinuxlog-$$.txt"
  else
    local tmnt="/tmp/.mylinux-$$"
    local log="/tmp/.mylinuxlog-$$.txt"
  fi
  
  free_line
  echo -ne "读取系统信息... 50%\r"
  if [[ ! -d $tmnt ]];then
    $bbox mkdir -p -m 755 $tmnt &>$log || {
      echo
      error_exit "无法创建临时挂载点失败";
    }
  fi
  
  free_line
  echo -ne "读取系统信息... 100%\r\n"
  
  free_line
  echo -ne "创建系统 [准备]... 0%\r"
  if [[ "$flag_loop" == true ]];then
    free_line
    echo -ne "创建系统 [制作镜像]... 0%\r"
    dd if=/dev/zero of=$path bs=1M count=$size &>>$log || {
      echo
      error_exit "无法创建虚拟镜像";
    }
    free_line
    echo -ne "创建系统 [格式化镜像]... 25%\r"
    $fscmd $fsarg $path &>>$log || {
      echo
      error_exit "无法格式化镜像"
    }
  fi
  
  free_line
  echo -ne "创建系统 [挂载文件系统]... 30%\r"
  $bbox mount -t $type -o rw $path $tmnt &>>$log || {
    echo
    error_exit "无法挂载文件系统"
  }
  
  free_line
  echo -ne "创建系统 [安装根文件系统]... 50%\r"
  $bbox tar xf $roottar -C $tmnt &>>$log || {
    echo
    error_exit "无法安装根文件系统"
  }
  
  free_line
  echo -ne "创建系统 [安装启动文件]... 75%\r"
  klinux_install_loader "$tmnt"
  
  free_line
  echo -ne "创建系统 [卸载文件系统]... 85%\r"
  local pid
  for pid in `$bbox lsof | $bbox grep $tmnt | $bbox sed -e's/  / /g' | $bbox cut -d' ' -f2`; do
    $bbox kill -9 $pid &>>$log
  done
  $bbox umount $tmnt &>>$log || {
    echo
    error_exit "无法卸载文件系统"
  }
  
  free_line
  echo -ne "创建系统 [清理]... 95%\r"
  $bbox rm -f $log
  $bbox rm -rf $tmnt
  
  free_line
  echo -ne "创建系统 [完成] 100%\r\n"
}



#  格式:
#  img_file::mount_point::fs_type
#  /sdcard/c.img::/media/c::ext4
#  /sdcard/d.img::/usr/disk/d::ext2
#  /data/local/e.img::/opt/e::vfat

function klinux_disk(){
  local tab="$1"
  if [[ ! -f "$tab" ]];then
    return
  fi
  
  echo " * [Loader] 挂载磁盘分区"
  echo -n "" > $disktab_suc
  local line
  while read line; do
    if [[ "$line"x == ""x ]];then
      continue
    fi
    
    local img="$(echo $line | $bbox awk -F'::' '{print $1}')"
    local mnp="$(echo $line | $bbox awk -F'::' '{print $2}')"
    local mtype="$(echo $line | $bbox awk -F'::' '{print $3}')"
    
    if [[ "$img"x == ""x || "$mnp"x == ""x ]];then
      continue
    fi
    
    if [[ "$mtype"x == ""x ]];then
      mtype="ext4"
    fi
    
    local realmnp="$mnt/$mnp"
    
    if [[ ! -f "$img" ]];then
      echo " * [Loader] 磁盘未找到: $img"
      continue
    fi
    
    if [[ ! -d "$realmnp" ]];then
      $bbox mkdir -m 755 -p "$realmnp"
    fi
    
    echo " * 挂载 $($bbox basename $img) 到 $mnp"
    $bbox mount -o rw -t "$mtype" "$img" "$realmnp"
    if [[ "$?" == "0" ]];then
      echo "$realmnp" >> $disktab_suc
      
      # 检测是否是一个系统
      if [[ -x "$realmnp/$boot" ]];then
        local index=$systems_index
        systems_title[index]="来自 $mnp"
        systems_root[index]="$realmnp"
        let systems_index++
      fi
      
    else
      echo " * 挂载磁盘 $(basename $img) 失败"
    fi
    
  done < $tab
}



# 卸载
function klinux_umount (){
  info "卸载文件系统"
  if [[ "$nosd1" != true ]];then
    $bbox umount $mnt/sdcard1 2>/dev/null
  fi
  if [[ "$nosd0" != true ]];then
    $bbox umount $mnt/sdcard0 2>/dev/null
  fi
  $bbox umount $mnt/dev/pts 2>/dev/null
  $bbox umount $mnt/dev  2>/dev/null
  $bbox umount $mnt/proc 2>/dev/null
  $bbox umount $mnt/sys 2>/dev/null
  $bbox umount $mnt 2>/dev/null
  info.ok
}



function klinux_udisk() {
  if [[ ! -f "$disktab_suc" ]];then
    return
  fi
  
  local line
  while read line;do
    
    if [[ "$line"x == ""x ]];then
      continue
    fi
    
    info "卸载磁盘 ${line##$mnt}"
    $bbox umount "$line"
    if [[ "$?" != "0" ]];then
      info.fail
    else
      info.ok
      $bbox rmdir "$line" &>/dev/null
    fi
    
  done < $disktab_suc
  echo > $disktab_suc
}



# 挂载
function klinux_mount(){
  info "挂载 Linux 分区"
  
  mmkdir "$mnt"
  $bbox mount -o rw -t $device_type $device $mnt
  if [ $? -ne 0 ];then
    info.fail
    error_exit "无法挂载 Linux 分区!"; 
  fi
  info.ok
  
  info "挂载 /dev/pts"
  mmkdir "$mnt/dev/pts" 
  $bbox mount -t devpts devpts $mnt/dev/pts
  if [ $? -ne 0 ];then 
    info.fail
    error_exit "无法挂载 /dev/pts!"; 
  fi
  info.ok
  
  info "挂载 /proc"
  mmkdir "$mnt/proc"
  $bbox mount -t proc proc $mnt/proc
  if [ $? -ne 0 ];then 
    info.fail
    error_exit "无法挂载 /proc!"; 
  fi
  info.ok
  
  info "挂载 /sys"
  mmkdir "$mnt/sys"
  $bbox mount -t sysfs sysfs $mnt/sys
  if [ $? -ne 0 ];then
    info.fail
    error_exit "无法挂载 /sys!"; 
  fi
  info.ok
  
  if [[ "$nosd0" != true ]];then
    info "挂载 $sd0"
    mmkdir "$mnt/sdcard0"
    $bbox mount -o bind $sd0 $mnt/sdcard0
    if [ $? -ne 0 ];then
      info.fail
      error_exit "无法挂载 /storage/sdcard0!";
    fi
    info.ok
  fi
  
  if [[ "$nosd1" != true ]];then
    info "挂载 $sd1"
    mmkdir "$mnt/sdcard1"
    $bbox mount -o bind $sd1 $mnt/sdcard1
    if [ $? -ne 0 ];then
      info.fail
      error_exit "无法挂载 /storage/sdcard1!";
    fi
    info.ok
  fi
}


# 网络
function klinux_network(){
  #echo -n " * [Loader] 网络: "
  $bbox sysctl -w net.ipv4.ip_forward=1 &>/dev/null
  if [ $? -ne 0 ];then 
    error_exit "无法获取网络信息"
  fi
}


# 第一次使用
function klinux_first_use(){
  :
}


function klinux_start_svc() {
  return
  local svc
  for svc in $(ls $mnt/etc/init.d); do
    info "启动服务 $svc"
    usleep $((RANDOM * 10)) &>/dev/null
    info.ok
  done
}

function klinux_stop_svc() {
  return
  local svc
  for svc in $(ls $mnt/etc/init.d); do
    info "停止服务 $svc"
    usleep $((RANDOM * 10)) &>/dev/null
    info.ok
  done
}


# 进入
function klinux_chroot(){
  local arg=
  local mmnt="$mnt"
  local mboot="$boot"
  
  if [[ "$systems_index" -gt 1 ]];then
    echo
    echo
    echo "   Klinux 启动管理器"
    echo "   ------------------------------------------------"
    echo "      磁盘分区中查找到了特殊的分区"
    echo "      他们可以被 Klinux 引导并启动"
    echo "      请选择一个将要启动的系统"
    echo
    local i
    for (( i=0 ; i<systems_index ; i++ ));do
      echo "       $i - ${systems_title[i]}"
    done
    echo
    echo "   ------------------------------------------------"
    echo "   ${wait_time}秒后默认进入: ${systems_title[0]}"
    echo -n "   您的选择: "
    local num="$default_system_idx"
    read -t $wait_time num
    echo
    echo
    local root="${systems_root[num]}"
    if [[ "$root"x != ""x ]];then
      mmnt="$root"
    fi
  fi
  
  if [[ "$already_mount" != true ]];then
    #echo " * [Kernel] 初始化内核服务"
    info "初始化内核服务"
    info.ok
    klinux_start_svc
  else
    arg='already-init'
  fi
  
  if [[ ! -f "$mmnt/$mboot" ]];then
    info "安装目标加载器"
    klinux_install_loader "$mmnt"
    info.ok
  fi
  
  $bbox chroot $mmnt $mboot $arg "$@"
  
  if [[ "$already_mount" != true ]];then
    #echo " * [Kernel] 停止内核服务"
    info "停止内核服务"
    info.ok
    klinux_stop_svc
  fi
}


# 关闭
function klinux_kill(){
  #echo -n " * 关闭 Linux ARM                             "
  info "停止所有进程"
  for pid in $($bbox lsof | $bbox grep $mnt | $bbox sed -e's/  / /g' | $bbox cut -d' ' -f2); do
    $bbox kill -9 $pid >/dev/null 2>&1
  done
  #gprint "[ OK ]"
  info.ok
}



function klinux_install_loader() {
  local dev="$1"
  local devtype="$2"
  local dir isdev
  
  if [[ "$dev"x == ""x ]];then
    dev="$device"
  fi
  
  if [[ "$devtype"x == ""x ]];then
    devtype="$device_type"
  fi
  
  if [[ "$dev"x == ""x ]];then
    error_exit "没有可以安装加载器的设备";
  fi
  
  if [[ -d "$dev" ]];then
    isdev=false
    dir="$dev"
  else
    isdev=true
    $bbox mount -o rw -t $devtype $dev $mnt || {
      error_exit "无法挂载 $dev"
    }
    dir="$mnt"
  fi
  
  if [[ ! -d "$dir/boot" ]];then
    mmkdir "$dir/boot"
  fi
  
  if [[ -d "$dir/boot/krub.d" ]];then
    $bbox rm -rf "$dir/boot/krub.d"
  fi
  
  mmkdir "$dir/boot/krub.d"
  mmkdir "$dir/boot/krub.d/etc"
  mmkdir "$dir/boot/krub.d/conf.d"
  
  mtouch "$dir/boot/krub.d/etc/disk-table"
  mtouch "$dir/boot/krub.d/etc/welcome"
  mtouch "$dir/boot/krub.d/krub"
  
  chmod 755 "$dir/boot/krub.d/krub"
  
  echo "$(get_section welcome_text)" > "$dir/boot/krub.d/etc/welcome"
  echo "$(get_section target_loader)" > "$dir/boot/krub.d/krub"
  
  local pwd="$PWD"
  cd "$dir/boot"
  $bbox ln -sf ./krub.d/krub ./krub
  cd "$pwd"
  
  if [[ "$isdev" == true ]];then
    $bbox umount "$dir"
  fi
}



# 默认启动
function klinux_main(){
  clear
  echo " * 启动 Linux ARM"
  echo
  if [[ -d $mnt/usr ]];then
    already_mount=true
    echo " * [Loader] 分区已被挂载 - 直接登陆"
  else
    klinux_mount
    if [[ -f $disktab_user ]];then
      cat $disktab_user >> $disktab_tmp
    fi
    klinux_disk $disktab_tmp
    klinux_network
    klinux_first_use
  fi
  klinux_chroot "$@"
  if [[ "$already_mount" != true ]];then
    klinux_kill
    klinux_udisk
    klinux_umount
  fi
  echo
}



function klinux_help() {
  klinux_version
  get_section "help_text"
  return 0
}



function klinux_version() {
  get_section "version_text"
  return 0
}



function klinux_license() {
  get_section "license"
  return 0
}



function rprint() {
  echo -ne "\033[1m\033[31m$@\033[0m"
}



function gprint() {
  echo -ne "\033[1m\033[32m$@\033[0m"
}



function info() {
  echo -ne "\r        $@\r "
}



function info.ok() {
  echo -ne "\r ["
  gprint " OK "
  echo -e "] "
}



function info.fail() {
  echo -ne "\r ["
  rprint "FAIL"
  echo -e "] "
}



function error_exit() {
  echo -n " * [Loader] 错误: "
  rprint "$@"
  echo
  exit 1
}



function free_line() {
  printf "%50c\r" " "
}



function mmkdir() {
  if [[ -d "$1" ]];then
    return
  fi
  
  $bbox mkdir -m 755 "$1"
  $bbox chown 0.0 "$1"
}



function mtouch() {
  if [[ -f "$1" ]];then
    return
  fi
  
  $bbox touch "$1"
  $bbox chmod 644 "$1"
  $bbox chown 0.0 "$1"
}
  


# ini 文件读写库
function ini.read() {
  local INIFILE="$1"
  local SECTION="$2"
  local ITEM="$3"
  
  $bbox awk -F '=' '/\['$SECTION'\]/{isSec=1}isSec==1 && $1~/'$ITEM'/{print $2;isSec=0}' $INIFILE
}



function ini.write() {
  local INIFILE="$1"
  local SECTION="$2"
  local ITEM="$3"
  local NEWVAL="${@:4}"
  $bbox sed -i \
    "/^\[$SECTION\]/,/^\[/ {/^\[$SECTION\]/b;/^\[/b;s/^$ITEM*=.*/$ITEM=$NEWVAL/g;}" "$INIFILE"
}



function ini() {
  if [[ "$4"x == ""x ]] ;then
    ini.read "$1" "$2" "$3"
  else
    ini.write "$1" "$2" "$3" "${@:4}"
  fi
}



function get_section() {
  local start="# section(\\\"$1\\\");"
  local end="# end(\\\"$1\\\");"
  
  $bbox awk "
    \$0 == \"${start}\" {
      flag = 1;
      skip = 1;
    }
    \$0 == \"${end}\" {
      flag = 0;
    }
    flag == 1 && skip == 0 {
      print \$0
    }
    
    skip = 0;
  " $0
}



init_myself

while [[ "$1"x != ""x ]];do
  case "$1" in
  
    cfg=* )
      arg="${1##cfg=}"
      if [[ "$arg"x != ""x ]];then
        klinux_parse_cfg "$arg"
      fi 
      shift ;;
      
    disktab=* )
      arg="${1##disktab=}"
      if [[ "$arg"x != ""x && -f "$arg" ]];then
        disktab_user="$arg"
      else
        rprint " * [Loader] 磁盘表文件不存在."
      fi
      shift ;;
      
    device=* )
      arg="${1##device=}"
      if [[ "$arg"x != ""x ]];then
        device="$arg"
      fi
      shift ;;
      
    mnt=* )
      arg="${1##mnt=}"
      if [[ "$arg"x != ""x ]];then
        mnt="$arg"
        update_var_depend_mnt
      fi
      shift ;;
      
    type=* )
      arg="${1##type=}"
      if [[ "$arg"x != ""x ]];then
        device_type="$arg"
      fi
      shift ;;
    
    wait=* )
      arg="${1##wait=}"
      argtmp="${arg//[0-9]/}"
      if [[ "$argtmp"x == ""x ]];then
      	wait_time="$arg"
      fi
      shift ;;
      
    "-f" )
      shift
      klinux_load_from_file "$1" ;;
      
    "--no-sdcard0" ) 
      shift
      nosd0=true ;;
    
    "--no-sdcard1" ) 
      shift
      nosd1=true ;;
    
    "--no-sdcard" ) 
      shift
      nosd0=true
      nosd1=true ;;
    
    "--no-clear" )
      shift
      noclear=true ;;
      
    "--kill" ) 
      shift
      klinux_kill
      exit ;;
            
    "--mount" )
      shift
      klinux_mount
      if [[ -f $disktab_user ]];then
        cat $disktab_user >> $disktab_tmp
      fi
      klinux_disk $disktab_tmp
      exit ;;
            
    "--umount" )
      shift
      klinux_udisk
      klinux_umount
      exit ;;
          
    "--network" )
      shift
      klinux_network
      exit ;;
            
    "--shutdown" | "--close" )
      klinux_kill
      klinux_udisk
      klinux_umount
      exit ;;
            
    "--boot" | "--open" )
      klinux_mount
      if [[ -f $disktab_user ]];then
        cat $disktab_user >> $disktab_tmp
      fi
      klinux_disk $disktab_tmp
      klinux_chroot
      exit ;;
            
    "--create" )
      shift
      klinux_create "$@"
      exit $? ;;
      
    "--install-loader" )
      shift
      klinux_install_loader "$@"
      exit $? ;;
      
    "--help" )
      klinux_help 
      exit 0 ;;
      
    "--version" )
      klinux_version
      exit 0 ;;
     
    "--license" )
      klinux_license
      exit 0 ;;
            
    "--" )
      shift
      break ;;
    * )
      error_exit "不支持的命令: $1"
      exit ;;
  esac
done

# 如果while中没处理到任何参数，默认运行
klinux_main "$@"

exit $?
# end("host_loader");


# section("target_loader");
#!/bin/bash

error_exit() {
    echo " * [Loader] 错误: $@"
    exit 1
}


mydir=/boot/krub.d
myconfd=$mydir/conf.d
myetc=$mydir/etc


export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/sbin:/usr/local/bin:/usr/games
export TERM=linux
export HOME=/root
export USER=root

already_init=false

INIT=/bin/bash
INIT_ARG="--login -i -"

while [[ ! -z "$1" ]];do
    
    case "$1" in
        
        init=* )
            pre="$(which ${1##*init=})"
            if test -x "$pre"; then
                INIT_ARG=
                INIT="$pre"
            fi
            unset pre
            shift 1 ;;
            
        initarg=* )
            INIT_ARG="${1##*initarg=}"
            shift 1 ;;
            
        path=* )
            pa="${1##*path=}"
            export PATH="$PATH:$pa"
            shift 1 ;;
            
        term=* )
            export TERM="${1##*term=}"
            shift 1 ;;
            
        home=* )
            pre="${1##*home=}"
            if test -d "$pre";then 
                export HOME="$pre"
            fi
            unset pre
            shift 1 ;;
            
        user=* )
            pre="${1##*user=}"
            if ! grep "$pre" /etc/shadow &>/dev/null;then
              error_echo "无法找到指定用户: $pre"
            fi
            export USER="$pre"
            export HOME=/home/$USER
            shift 1 ;;
            
        already-init )
            shift 1
            already_init=true ;;
            
        * )
            error_exit "$1: 暂不支持的启动参数"
            exit 1 ;;
        
    esac
    
done


if [[ "$already_init" != true ]];then
    if ! test -f $myconfd/DONOTDELETE.txt;  then
        echo " * 正在为第一次启动进行配置..."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf || {
            error_exit "无法写入 resolv.conf 文件!"
        }
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
        echo "127.0.0.1 localhost" > /etc/hosts || {
            error_exit "无法写入 hosts 文件!";
        }
        chmod a+rw  /dev/null &>/dev/null
        chmod a+rw  /dev/ptmx &>/dev/null
        chmod 1777 /tmp &>/dev/null
        chmod 1777 /dev/shm &>/dev/null
        chmod +s /usr/bin/sudo &>/dev/null
        groupadd -g 3001 android_bt &>/dev/null
        groupadd -g 3002 android_bt-net &>/dev/null
        groupadd -g 3003 android_inet &>/dev/null
        groupadd -g 3004 android_net-raw &>/dev/null
        mkdir /var/run/dbus &>/dev/null
        chmod 755 /var/run/dbus &>/dev/null
        echo "shm /dev/shm tmpfs nodev,nosuid,noexec 0 0" >> /etc/fstab
        cd ~
        groupadd -g 1015 sdcard-rw &>/dev/null
        echo "boot set donotdelete" >> $myconfd/DONOTDELETE.txt
        
    fi
    if ! test -f $myconfd/welcome_showed;then
      if test -f $myetc/welcome;then
        cat $myetc/welcome
        echo "showed" > $myconfd/welcome_showed
      fi
    fi
fi



if [[ "$already_init" != true ]];then
    rm /tmp/.X* &>/dev/null
    rm /tmp/.X11-unix/X* &>/dev/null
    rm /root/.vnc/localhost* &>/dev/null
    rm /var/run/dbus/pid &>/dev/null
    rm /var/run/reboot-required* &>/dev/null
fi

ln -s /bin/true /sbin/initctl &>/dev/null

echo

cd $HOME
su $USER - -c "$INIT $INIT_ARG"

clear
echo " * 关闭 Linux ARM"
echo
exit 0
# end("target_loader");



# section("welcome_text");

    _  ___      _                  
   | |/ / |    (_)                 
   | ' /| |     _ _ __  _   ___  __
   |  < | |    | | '_ \| | | \ \/ /
   | . \| |____| | | | | |_| |>  < 
   |_|\_\______|_|_| |_|\__,_/_/\_\


   Hello Klinux!
   感谢您使用 Klinux 作为加载器
   ---------------------------------------
   祝您愉快使用！
   
   发送 Bug: Kiva <kiva515@foxmail.com>



# end("welcome_text");

# section("version_text");
Klinux - 1.0(20160217)
# end("version_text");

# section("help_text");
Klinux: A fast and smart linux-arm loader
usage: linux [options] [command]

options:
  device=DEVICE    使用 DEVICE 作为根设备
  type=FSTYPE      使用 FSTYPE 作为根设备文件系统类型
  mnt=DIR          使用 DIR 作为挂载点
  cfg=FILE         使用 FILE 作为配置文件
  disktab=FILE     使用 FILE 作为额外的挂载表
  wait=SECONDS     使用 SECONDS 作为等待启动时间
  
  --no-sdcard0     不挂载 /storage/sdcard0
  --no-sdcard1     不挂载 /storage/sdcard1
  --no-sdcard      不挂载全部 sdcard 设备
 
command:
  --mount          只执行挂载文件系统的操作
  --unmount        只执行卸载文件系统的操作
  --kill           杀死所有占用文件系统的进程
  --boot           启动 linux-arm [默认操作]
  --shutdown       退出 linux-arm
  --open           与 --boot 相同
  --close          与 --shutdown 相同
  --create         创建一个可启动的 linux-arm
  --install-loader 为 linux-arm 安装启动文件
  
  --help           打印这些信息
  --license        打印开源协议
  
如果没有指定任何一个 command
则默认执行参数 --boot 的操作

# end("help_text");


# section("license");
                    GNU GENERAL PUBLIC LICENSE
                       Version 3, 29 June 2007

 Copyright (C) 2007 Free Software Foundation, Inc. <http://fsf.org/>
 Everyone is permitted to copy and distribute verbatim copies
 of this license document, but changing it is not allowed.

                            Preamble

  The GNU General Public License is a free, copyleft license for
software and other kinds of works.

  The licenses for most software and other practical works are designed
to take away your freedom to share and change the works.  By contrast,
the GNU General Public License is intended to guarantee your freedom to
share and change all versions of a program--to make sure it remains free
software for all its users.  We, the Free Software Foundation, use the
GNU General Public License for most of our software; it applies also to
any other work released this way by its authors.  You can apply it to
your programs, too.

  When we speak of free software, we are referring to freedom, not
price.  Our General Public Licenses are designed to make sure that you
have the freedom to distribute copies of free software (and charge for
them if you wish), that you receive source code or can get it if you
want it, that you can change the software or use pieces of it in new
free programs, and that you know you can do these things.

  To protect your rights, we need to prevent others from denying you
these rights or asking you to surrender the rights.  Therefore, you have
certain responsibilities if you distribute copies of the software, or if
you modify it: responsibilities to respect the freedom of others.

  For example, if you distribute copies of such a program, whether
gratis or for a fee, you must pass on to the recipients the same
freedoms that you received.  You must make sure that they, too, receive
or can get the source code.  And you must show them these terms so they
know their rights.

  Developers that use the GNU GPL protect your rights with two steps:
(1) assert copyright on the software, and (2) offer you this License
giving you legal permission to copy, distribute and/or modify it.

  For the developers' and authors' protection, the GPL clearly explains
that there is no warranty for this free software.  For both users' and
authors' sake, the GPL requires that modified versions be marked as
changed, so that their problems will not be attributed erroneously to
authors of previous versions.

  Some devices are designed to deny users access to install or run
modified versions of the software inside them, although the manufacturer
can do so.  This is fundamentally incompatible with the aim of
protecting users' freedom to change the software.  The systematic
pattern of such abuse occurs in the area of products for individuals to
use, which is precisely where it is most unacceptable.  Therefore, we
have designed this version of the GPL to prohibit the practice for those
products.  If such problems arise substantially in other domains, we
stand ready to extend this provision to those domains in future versions
of the GPL, as needed to protect the freedom of users.

  Finally, every program is threatened constantly by software patents.
States should not allow patents to restrict development and use of
software on general-purpose computers, but in those that do, we wish to
avoid the special danger that patents applied to a free program could
make it effectively proprietary.  To prevent this, the GPL assures that
patents cannot be used to render the program non-free.

  The precise terms and conditions for copying, distribution and
modification follow.

                       TERMS AND CONDITIONS

  0. Definitions.

  "This License" refers to version 3 of the GNU General Public License.

  "Copyright" also means copyright-like laws that apply to other kinds of
works, such as semiconductor masks.

  "The Program" refers to any copyrightable work licensed under this
License.  Each licensee is addressed as "you".  "Licensees" and
"recipients" may be individuals or organizations.

  To "modify" a work means to copy from or adapt all or part of the work
in a fashion requiring copyright permission, other than the making of an
exact copy.  The resulting work is called a "modified version" of the
earlier work or a work "based on" the earlier work.

  A "covered work" means either the unmodified Program or a work based
on the Program.

  To "propagate" a work means to do anything with it that, without
permission, would make you directly or secondarily liable for
infringement under applicable copyright law, except executing it on a
computer or modifying a private copy.  Propagation includes copying,
distribution (with or without modification), making available to the
public, and in some countries other activities as well.

  To "convey" a work means any kind of propagation that enables other
parties to make or receive copies.  Mere interaction with a user through
a computer network, with no transfer of a copy, is not conveying.

  An interactive user interface displays "Appropriate Legal Notices"
to the extent that it includes a convenient and prominently visible
feature that (1) displays an appropriate copyright notice, and (2)
tells the user that there is no warranty for the work (except to the
extent that warranties are provided), that licensees may convey the
work under this License, and how to view a copy of this License.  If
the interface presents a list of user commands or options, such as a
menu, a prominent item in the list meets this criterion.

  1. Source Code.

  The "source code" for a work means the preferred form of the work
for making modifications to it.  "Object code" means any non-source
form of a work.

  A "Standard Interface" means an interface that either is an official
standard defined by a recognized standards body, or, in the case of
interfaces specified for a particular programming language, one that
is widely used among developers working in that language.

  The "System Libraries" of an executable work include anything, other
than the work as a whole, that (a) is included in the normal form of
packaging a Major Component, but which is not part of that Major
Component, and (b) serves only to enable use of the work with that
Major Component, or to implement a Standard Interface for which an
implementation is available to the public in source code form.  A
"Major Component", in this context, means a major essential component
(kernel, window system, and so on) of the specific operating system
(if any) on which the executable work runs, or a compiler used to
produce the work, or an object code interpreter used to run it.

  The "Corresponding Source" for a work in object code form means all
the source code needed to generate, install, and (for an executable
work) run the object code and to modify the work, including scripts to
control those activities.  However, it does not include the work's
System Libraries, or general-purpose tools or generally available free
programs which are used unmodified in performing those activities but
which are not part of the work.  For example, Corresponding Source
includes interface definition files associated with source files for
the work, and the source code for shared libraries and dynamically
linked subprograms that the work is specifically designed to require,
such as by intimate data communication or control flow between those
subprograms and other parts of the work.

  The Corresponding Source need not include anything that users
can regenerate automatically from other parts of the Corresponding
Source.

  The Corresponding Source for a work in source code form is that
same work.

  2. Basic Permissions.

  All rights granted under this License are granted for the term of
copyright on the Program, and are irrevocable provided the stated
conditions are met.  This License explicitly affirms your unlimited
permission to run the unmodified Program.  The output from running a
covered work is covered by this License only if the output, given its
content, constitutes a covered work.  This License acknowledges your
rights of fair use or other equivalent, as provided by copyright law.

  You may make, run and propagate covered works that you do not
convey, without conditions so long as your license otherwise remains
in force.  You may convey covered works to others for the sole purpose
of having them make modifications exclusively for you, or provide you
with facilities for running those works, provided that you comply with
the terms of this License in conveying all material for which you do
not control copyright.  Those thus making or running the covered works
for you must do so exclusively on your behalf, under your direction
and control, on terms that prohibit them from making any copies of
your copyrighted material outside their relationship with you.

  Conveying under any other circumstances is permitted solely under
the conditions stated below.  Sublicensing is not allowed; section 10
makes it unnecessary.

  3. Protecting Users' Legal Rights From Anti-Circumvention Law.

  No covered work shall be deemed part of an effective technological
measure under any applicable law fulfilling obligations under article
11 of the WIPO copyright treaty adopted on 20 December 1996, or
similar laws prohibiting or restricting circumvention of such
measures.

  When you convey a covered work, you waive any legal power to forbid
circumvention of technological measures to the extent such circumvention
is effected by exercising rights under this License with respect to
the covered work, and you disclaim any intention to limit operation or
modification of the work as a means of enforcing, against the work's
users, your or third parties' legal rights to forbid circumvention of
technological measures.

  4. Conveying Verbatim Copies.

  You may convey verbatim copies of the Program's source code as you
receive it, in any medium, provided that you conspicuously and
appropriately publish on each copy an appropriate copyright notice;
keep intact all notices stating that this License and any
non-permissive terms added in accord with section 7 apply to the code;
keep intact all notices of the absence of any warranty; and give all
recipients a copy of this License along with the Program.

  You may charge any price or no price for each copy that you convey,
and you may offer support or warranty protection for a fee.

  5. Conveying Modified Source Versions.

  You may convey a work based on the Program, or the modifications to
produce it from the Program, in the form of source code under the
terms of section 4, provided that you also meet all of these conditions:

    a) The work must carry prominent notices stating that you modified
    it, and giving a relevant date.

    b) The work must carry prominent notices stating that it is
    released under this License and any conditions added under section
    7.  This requirement modifies the requirement in section 4 to
    "keep intact all notices".

    c) You must license the entire work, as a whole, under this
    License to anyone who comes into possession of a copy.  This
    License will therefore apply, along with any applicable section 7
    additional terms, to the whole of the work, and all its parts,
    regardless of how they are packaged.  This License gives no
    permission to license the work in any other way, but it does not
    invalidate such permission if you have separately received it.

    d) If the work has interactive user interfaces, each must display
    Appropriate Legal Notices; however, if the Program has interactive
    interfaces that do not display Appropriate Legal Notices, your
    work need not make them do so.

  A compilation of a covered work with other separate and independent
works, which are not by their nature extensions of the covered work,
and which are not combined with it such as to form a larger program,
in or on a volume of a storage or distribution medium, is called an
"aggregate" if the compilation and its resulting copyright are not
used to limit the access or legal rights of the compilation's users
beyond what the individual works permit.  Inclusion of a covered work
in an aggregate does not cause this License to apply to the other
parts of the aggregate.

  6. Conveying Non-Source Forms.

  You may convey a covered work in object code form under the terms
of sections 4 and 5, provided that you also convey the
machine-readable Corresponding Source under the terms of this License,
in one of these ways:

    a) Convey the object code in, or embodied in, a physical product
    (including a physical distribution medium), accompanied by the
    Corresponding Source fixed on a durable physical medium
    customarily used for software interchange.

    b) Convey the object code in, or embodied in, a physical product
    (including a physical distribution medium), accompanied by a
    written offer, valid for at least three years and valid for as
    long as you offer spare parts or customer support for that product
    model, to give anyone who possesses the object code either (1) a
    copy of the Corresponding Source for all the software in the
    product that is covered by this License, on a durable physical
    medium customarily used for software interchange, for a price no
    more than your reasonable cost of physically performing this
    conveying of source, or (2) access to copy the
    Corresponding Source from a network server at no charge.

    c) Convey individual copies of the object code with a copy of the
    written offer to provide the Corresponding Source.  This
    alternative is allowed only occasionally and noncommercially, and
    only if you received the object code with such an offer, in accord
    with subsection 6b.

    d) Convey the object code by offering access from a designated
    place (gratis or for a charge), and offer equivalent access to the
    Corresponding Source in the same way through the same place at no
    further charge.  You need not require recipients to copy the
    Corresponding Source along with the object code.  If the place to
    copy the object code is a network server, the Corresponding Source
    may be on a different server (operated by you or a third party)
    that supports equivalent copying facilities, provided you maintain
    clear directions next to the object code saying where to find the
    Corresponding Source.  Regardless of what server hosts the
    Corresponding Source, you remain obligated to ensure that it is
    available for as long as needed to satisfy these requirements.

    e) Convey the object code using peer-to-peer transmission, provided
    you inform other peers where the object code and Corresponding
    Source of the work are being offered to the general public at no
    charge under subsection 6d.

  A separable portion of the object code, whose source code is excluded
from the Corresponding Source as a System Library, need not be
included in conveying the object code work.

  A "User Product" is either (1) a "consumer product", which means any
tangible personal property which is normally used for personal, family,
or household purposes, or (2) anything designed or sold for incorporation
into a dwelling.  In determining whether a product is a consumer product,
doubtful cases shall be resolved in favor of coverage.  For a particular
product received by a particular user, "normally used" refers to a
typical or common use of that class of product, regardless of the status
of the particular user or of the way in which the particular user
actually uses, or expects or is expected to use, the product.  A product
is a consumer product regardless of whether the product has substantial
commercial, industrial or non-consumer uses, unless such uses represent
the only significant mode of use of the product.

  "Installation Information" for a User Product means any methods,
procedures, authorization keys, or other information required to install
and execute modified versions of a covered work in that User Product from
a modified version of its Corresponding Source.  The information must
suffice to ensure that the continued functioning of the modified object
code is in no case prevented or interfered with solely because
modification has been made.

  If you convey an object code work under this section in, or with, or
specifically for use in, a User Product, and the conveying occurs as
part of a transaction in which the right of possession and use of the
User Product is transferred to the recipient in perpetuity or for a
fixed term (regardless of how the transaction is characterized), the
Corresponding Source conveyed under this section must be accompanied
by the Installation Information.  But this requirement does not apply
if neither you nor any third party retains the ability to install
modified object code on the User Product (for example, the work has
been installed in ROM).

  The requirement to provide Installation Information does not include a
requirement to continue to provide support service, warranty, or updates
for a work that has been modified or installed by the recipient, or for
the User Product in which it has been modified or installed.  Access to a
network may be denied when the modification itself materially and
adversely affects the operation of the network or violates the rules and
protocols for communication across the network.

  Corresponding Source conveyed, and Installation Information provided,
in accord with this section must be in a format that is publicly
documented (and with an implementation available to the public in
source code form), and must require no special password or key for
unpacking, reading or copying.

  7. Additional Terms.

  "Additional permissions" are terms that supplement the terms of this
License by making exceptions from one or more of its conditions.
Additional permissions that are applicable to the entire Program shall
be treated as though they were included in this License, to the extent
that they are valid under applicable law.  If additional permissions
apply only to part of the Program, that part may be used separately
under those permissions, but the entire Program remains governed by
this License without regard to the additional permissions.

  When you convey a copy of a covered work, you may at your option
remove any additional permissions from that copy, or from any part of
it.  (Additional permissions may be written to require their own
removal in certain cases when you modify the work.)  You may place
additional permissions on material, added by you to a covered work,
for which you have or can give appropriate copyright permission.

  Notwithstanding any other provision of this License, for material you
add to a covered work, you may (if authorized by the copyright holders of
that material) supplement the terms of this License with terms:

    a) Disclaiming warranty or limiting liability differently from the
    terms of sections 15 and 16 of this License; or

    b) Requiring preservation of specified reasonable legal notices or
    author attributions in that material or in the Appropriate Legal
    Notices displayed by works containing it; or

    c) Prohibiting misrepresentation of the origin of that material, or
    requiring that modified versions of such material be marked in
    reasonable ways as different from the original version; or

    d) Limiting the use for publicity purposes of names of licensors or
    authors of the material; or

    e) Declining to grant rights under trademark law for use of some
    trade names, trademarks, or service marks; or

    f) Requiring indemnification of licensors and authors of that
    material by anyone who conveys the material (or modified versions of
    it) with contractual assumptions of liability to the recipient, for
    any liability that these contractual assumptions directly impose on
    those licensors and authors.

  All other non-permissive additional terms are considered "further
restrictions" within the meaning of section 10.  If the Program as you
received it, or any part of it, contains a notice stating that it is
governed by this License along with a term that is a further
restriction, you may remove that term.  If a license document contains
a further restriction but permits relicensing or conveying under this
License, you may add to a covered work material governed by the terms
of that license document, provided that the further restriction does
not survive such relicensing or conveying.

  If you add terms to a covered work in accord with this section, you
must place, in the relevant source files, a statement of the
additional terms that apply to those files, or a notice indicating
where to find the applicable terms.

  Additional terms, permissive or non-permissive, may be stated in the
form of a separately written license, or stated as exceptions;
the above requirements apply either way.

  8. Termination.

  You may not propagate or modify a covered work except as expressly
provided under this License.  Any attempt otherwise to propagate or
modify it is void, and will automatically terminate your rights under
this License (including any patent licenses granted under the third
paragraph of section 11).

  However, if you cease all violation of this License, then your
license from a particular copyright holder is reinstated (a)
provisionally, unless and until the copyright holder explicitly and
finally terminates your license, and (b) permanently, if the copyright
holder fails to notify you of the violation by some reasonable means
prior to 60 days after the cessation.

  Moreover, your license from a particular copyright holder is
reinstated permanently if the copyright holder notifies you of the
violation by some reasonable means, this is the first time you have
received notice of violation of this License (for any work) from that
copyright holder, and you cure the violation prior to 30 days after
your receipt of the notice.

  Termination of your rights under this section does not terminate the
licenses of parties who have received copies or rights from you under
this License.  If your rights have been terminated and not permanently
reinstated, you do not qualify to receive new licenses for the same
material under section 10.

  9. Acceptance Not Required for Having Copies.

  You are not required to accept this License in order to receive or
run a copy of the Program.  Ancillary propagation of a covered work
occurring solely as a consequence of using peer-to-peer transmission
to receive a copy likewise does not require acceptance.  However,
nothing other than this License grants you permission to propagate or
modify any covered work.  These actions infringe copyright if you do
not accept this License.  Therefore, by modifying or propagating a
covered work, you indicate your acceptance of this License to do so.

  10. Automatic Licensing of Downstream Recipients.

  Each time you convey a covered work, the recipient automatically
receives a license from the original licensors, to run, modify and
propagate that work, subject to this License.  You are not responsible
for enforcing compliance by third parties with this License.

  An "entity transaction" is a transaction transferring control of an
organization, or substantially all assets of one, or subdividing an
organization, or merging organizations.  If propagation of a covered
work results from an entity transaction, each party to that
transaction who receives a copy of the work also receives whatever
licenses to the work the party's predecessor in interest had or could
give under the previous paragraph, plus a right to possession of the
Corresponding Source of the work from the predecessor in interest, if
the predecessor has it or can get it with reasonable efforts.

  You may not impose any further restrictions on the exercise of the
rights granted or affirmed under this License.  For example, you may
not impose a license fee, royalty, or other charge for exercise of
rights granted under this License, and you may not initiate litigation
(including a cross-claim or counterclaim in a lawsuit) alleging that
any patent claim is infringed by making, using, selling, offering for
sale, or importing the Program or any portion of it.

  11. Patents.

  A "contributor" is a copyright holder who authorizes use under this
License of the Program or a work on which the Program is based.  The
work thus licensed is called the contributor's "contributor version".

  A contributor's "essential patent claims" are all patent claims
owned or controlled by the contributor, whether already acquired or
hereafter acquired, that would be infringed by some manner, permitted
by this License, of making, using, or selling its contributor version,
but do not include claims that would be infringed only as a
consequence of further modification of the contributor version.  For
purposes of this definition, "control" includes the right to grant
patent sublicenses in a manner consistent with the requirements of
this License.

  Each contributor grants you a non-exclusive, worldwide, royalty-free
patent license under the contributor's essential patent claims, to
make, use, sell, offer for sale, import and otherwise run, modify and
propagate the contents of its contributor version.

  In the following three paragraphs, a "patent license" is any express
agreement or commitment, however denominated, not to enforce a patent
(such as an express permission to practice a patent or covenant not to
sue for patent infringement).  To "grant" such a patent license to a
party means to make such an agreement or commitment not to enforce a
patent against the party.

  If you convey a covered work, knowingly relying on a patent license,
and the Corresponding Source of the work is not available for anyone
to copy, free of charge and under the terms of this License, through a
publicly available network server or other readily accessible means,
then you must either (1) cause the Corresponding Source to be so
available, or (2) arrange to deprive yourself of the benefit of the
patent license for this particular work, or (3) arrange, in a manner
consistent with the requirements of this License, to extend the patent
license to downstream recipients.  "Knowingly relying" means you have
actual knowledge that, but for the patent license, your conveying the
covered work in a country, or your recipient's use of the covered work
in a country, would infringe one or more identifiable patents in that
country that you have reason to believe are valid.

  If, pursuant to or in connection with a single transaction or
arrangement, you convey, or propagate by procuring conveyance of, a
covered work, and grant a patent license to some of the parties
receiving the covered work authorizing them to use, propagate, modify
or convey a specific copy of the covered work, then the patent license
you grant is automatically extended to all recipients of the covered
work and works based on it.

  A patent license is "discriminatory" if it does not include within
the scope of its coverage, prohibits the exercise of, or is
conditioned on the non-exercise of one or more of the rights that are
specifically granted under this License.  You may not convey a covered
work if you are a party to an arrangement with a third party that is
in the business of distributing software, under which you make payment
to the third party based on the extent of your activity of conveying
the work, and under which the third party grants, to any of the
parties who would receive the covered work from you, a discriminatory
patent license (a) in connection with copies of the covered work
conveyed by you (or copies made from those copies), or (b) primarily
for and in connection with specific products or compilations that
contain the covered work, unless you entered into that arrangement,
or that patent license was granted, prior to 28 March 2007.

  Nothing in this License shall be construed as excluding or limiting
any implied license or other defenses to infringement that may
otherwise be available to you under applicable patent law.

  12. No Surrender of Others' Freedom.

  If conditions are imposed on you (whether by court order, agreement or
otherwise) that contradict the conditions of this License, they do not
excuse you from the conditions of this License.  If you cannot convey a
covered work so as to satisfy simultaneously your obligations under this
License and any other pertinent obligations, then as a consequence you may
not convey it at all.  For example, if you agree to terms that obligate you
to collect a royalty for further conveying from those to whom you convey
the Program, the only way you could satisfy both those terms and this
License would be to refrain entirely from conveying the Program.

  13. Use with the GNU Affero General Public License.

  Notwithstanding any other provision of this License, you have
permission to link or combine any covered work with a work licensed
under version 3 of the GNU Affero General Public License into a single
combined work, and to convey the resulting work.  The terms of this
License will continue to apply to the part which is the covered work,
but the special requirements of the GNU Affero General Public License,
section 13, concerning interaction through a network will apply to the
combination as such.

  14. Revised Versions of this License.

  The Free Software Foundation may publish revised and/or new versions of
the GNU General Public License from time to time.  Such new versions will
be similar in spirit to the present version, but may differ in detail to
address new problems or concerns.

  Each version is given a distinguishing version number.  If the
Program specifies that a certain numbered version of the GNU General
Public License "or any later version" applies to it, you have the
option of following the terms and conditions either of that numbered
version or of any later version published by the Free Software
Foundation.  If the Program does not specify a version number of the
GNU General Public License, you may choose any version ever published
by the Free Software Foundation.

  If the Program specifies that a proxy can decide which future
versions of the GNU General Public License can be used, that proxy's
public statement of acceptance of a version permanently authorizes you
to choose that version for the Program.

  Later license versions may give you additional or different
permissions.  However, no additional obligations are imposed on any
author or copyright holder as a result of your choosing to follow a
later version.

  15. Disclaimer of Warranty.

  THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY
APPLICABLE LAW.  EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT
HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY
OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE.  THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE PROGRAM
IS WITH YOU.  SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF
ALL NECESSARY SERVICING, REPAIR OR CORRECTION.

  16. Limitation of Liability.

  IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MODIFIES AND/OR CONVEYS
THE PROGRAM AS PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES, INCLUDING ANY
GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
USE OR INABILITY TO USE THE PROGRAM (INCLUDING BUT NOT LIMITED TO LOSS OF
DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD
PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER PROGRAMS),
EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

  17. Interpretation of Sections 15 and 16.

  If the disclaimer of warranty and limitation of liability provided
above cannot be given local legal effect according to their terms,
reviewing courts shall apply local law that most closely approximates
an absolute waiver of all civil liability in connection with the
Program, unless a warranty or assumption of liability accompanies a
copy of the Program in return for a fee.

                     END OF TERMS AND CONDITIONS

            How to Apply These Terms to Your New Programs

  If you develop a new program, and you want it to be of the greatest
possible use to the public, the best way to achieve this is to make it
free software which everyone can redistribute and change under these terms.

  To do so, attach the following notices to the program.  It is safest
to attach them to the start of each source file to most effectively
state the exclusion of warranty; and each file should have at least
the "copyright" line and a pointer to where the full notice is found.

    {one line to give the program's name and a brief idea of what it does.}
    Copyright (C) {year}  {name of author}

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

Also add information on how to contact you by electronic and paper mail.

  If the program does terminal interaction, make it output a short
notice like this when it starts in an interactive mode:

    {project}  Copyright (C) {year}  {fullname}
    This program comes with ABSOLUTELY NO WARRANTY; for details type `show w'.
    This is free software, and you are welcome to redistribute it
    under certain conditions; type `show c' for details.

The hypothetical commands `show w' and `show c' should show the appropriate
parts of the General Public License.  Of course, your program's commands
might be different; for a GUI interface, you would use an "about box".

  You should also get your employer (if you work as a programmer) or school,
if any, to sign a "copyright disclaimer" for the program, if necessary.
For more information on this, and how to apply and follow the GNU GPL, see
<http://www.gnu.org/licenses/>.

  The GNU General Public License does not permit incorporating your program
into proprietary programs.  If your program is a subroutine library, you
may consider it more useful to permit linking proprietary applications with
the library.  If this is what you want to do, use the GNU Lesser General
Public License instead of this License.  But first, please read
<http://www.gnu.org/philosophy/why-not-lgpl.html>.

# end("license");

