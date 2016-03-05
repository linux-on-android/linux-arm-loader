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

#!/system/bin/bash

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
                       Version 2, June 1991

 Copyright (C) 1989, 1991 Free Software Foundation, Inc., <http://fsf.org/>
 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 Everyone is permitted to copy and distribute verbatim copies
 of this license document, but changing it is not allowed.

                            Preamble

  The licenses for most software are designed to take away your
freedom to share and change it.  By contrast, the GNU General Public
License is intended to guarantee your freedom to share and change free
software--to make sure the software is free for all its users.  This
General Public License applies to most of the Free Software
Foundation's software and to any other program whose authors commit to
using it.  (Some other Free Software Foundation software is covered by
the GNU Lesser General Public License instead.)  You can apply it to
your programs, too.

  When we speak of free software, we are referring to freedom, not
price.  Our General Public Licenses are designed to make sure that you
have the freedom to distribute copies of free software (and charge for
this service if you wish), that you receive source code or can get it
if you want it, that you can change the software or use pieces of it
in new free programs; and that you know you can do these things.

  To protect your rights, we need to make restrictions that forbid
anyone to deny you these rights or to ask you to surrender the rights.
These restrictions translate to certain responsibilities for you if you
distribute copies of the software, or if you modify it.

  For example, if you distribute copies of such a program, whether
gratis or for a fee, you must give the recipients all the rights that
you have.  You must make sure that they, too, receive or can get the
source code.  And you must show them these terms so they know their
rights.

  We protect your rights with two steps: (1) copyright the software, and
(2) offer you this license which gives you legal permission to copy,
distribute and/or modify the software.

  Also, for each author's protection and ours, we want to make certain
that everyone understands that there is no warranty for this free
software.  If the software is modified by someone else and passed on, we
want its recipients to know that what they have is not the original, so
that any problems introduced by others will not reflect on the original
authors' reputations.

  Finally, any free program is threatened constantly by software
patents.  We wish to avoid the danger that redistributors of a free
program will individually obtain patent licenses, in effect making the
program proprietary.  To prevent this, we have made it clear that any
patent must be licensed for everyone's free use or not licensed at all.

  The precise terms and conditions for copying, distribution and
modification follow.

                    GNU GENERAL PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

  0. This License applies to any program or other work which contains
a notice placed by the copyright holder saying it may be distributed
under the terms of this General Public License.  The "Program", below,
refers to any such program or work, and a "work based on the Program"
means either the Program or any derivative work under copyright law:
that is to say, a work containing the Program or a portion of it,
either verbatim or with modifications and/or translated into another
language.  (Hereinafter, translation is included without limitation in
the term "modification".)  Each licensee is addressed as "you".

Activities other than copying, distribution and modification are not
covered by this License; they are outside its scope.  The act of
running the Program is not restricted, and the output from the Program
is covered only if its contents constitute a work based on the
Program (independent of having been made by running the Program).
Whether that is true depends on what the Program does.

  1. You may copy and distribute verbatim copies of the Program's
source code as you receive it, in any medium, provided that you
conspicuously and appropriately publish on each copy an appropriate
copyright notice and disclaimer of warranty; keep intact all the
notices that refer to this License and to the absence of any warranty;
and give any other recipients of the Program a copy of this License
along with the Program.

You may charge a fee for the physical act of transferring a copy, and
you may at your option offer warranty protection in exchange for a fee.

  2. You may modify your copy or copies of the Program or any portion
of it, thus forming a work based on the Program, and copy and
distribute such modifications or work under the terms of Section 1
above, provided that you also meet all of these conditions:

    a) You must cause the modified files to carry prominent notices
    stating that you changed the files and the date of any change.

    b) You must cause any work that you distribute or publish, that in
    whole or in part contains or is derived from the Program or any
    part thereof, to be licensed as a whole at no charge to all third
    parties under the terms of this License.

    c) If the modified program normally reads commands interactively
    when run, you must cause it, when started running for such
    interactive use in the most ordinary way, to print or display an
    announcement including an appropriate copyright notice and a
    notice that there is no warranty (or else, saying that you provide
    a warranty) and that users may redistribute the program under
    these conditions, and telling the user how to view a copy of this
    License.  (Exception: if the Program itself is interactive but
    does not normally print such an announcement, your work based on
    the Program is not required to print an announcement.)

These requirements apply to the modified work as a whole.  If
identifiable sections of that work are not derived from the Program,
and can be reasonably considered independent and separate works in
themselves, then this License, and its terms, do not apply to those
sections when you distribute them as separate works.  But when you
distribute the same sections as part of a whole which is a work based
on the Program, the distribution of the whole must be on the terms of
this License, whose permissions for other licensees extend to the
entire whole, and thus to each and every part regardless of who wrote it.

Thus, it is not the intent of this section to claim rights or contest
your rights to work written entirely by you; rather, the intent is to
exercise the right to control the distribution of derivative or
collective works based on the Program.

In addition, mere aggregation of another work not based on the Program
with the Program (or with a work based on the Program) on a volume of
a storage or distribution medium does not bring the other work under
the scope of this License.

  3. You may copy and distribute the Program (or a work based on it,
under Section 2) in object code or executable form under the terms of
Sections 1 and 2 above provided that you also do one of the following:

    a) Accompany it with the complete corresponding machine-readable
    source code, which must be distributed under the terms of Sections
    1 and 2 above on a medium customarily used for software interchange; or,

    b) Accompany it with a written offer, valid for at least three
    years, to give any third party, for a charge no more than your
    cost of physically performing source distribution, a complete
    machine-readable copy of the corresponding source code, to be
    distributed under the terms of Sections 1 and 2 above on a medium
    customarily used for software interchange; or,

    c) Accompany it with the information you received as to the offer
    to distribute corresponding source code.  (This alternative is
    allowed only for noncommercial distribution and only if you
    received the program in object code or executable form with such
    an offer, in accord with Subsection b above.)

The source code for a work means the preferred form of the work for
making modifications to it.  For an executable work, complete source
code means all the source code for all modules it contains, plus any
associated interface definition files, plus the scripts used to
control compilation and installation of the executable.  However, as a
special exception, the source code distributed need not include
anything that is normally distributed (in either source or binary
form) with the major components (compiler, kernel, and so on) of the
operating system on which the executable runs, unless that component
itself accompanies the executable.

If distribution of executable or object code is made by offering
access to copy from a designated place, then offering equivalent
access to copy the source code from the same place counts as
distribution of the source code, even though third parties are not
compelled to copy the source along with the object code.

  4. You may not copy, modify, sublicense, or distribute the Program
except as expressly provided under this License.  Any attempt
otherwise to copy, modify, sublicense or distribute the Program is
void, and will automatically terminate your rights under this License.
However, parties who have received copies, or rights, from you under
this License will not have their licenses terminated so long as such
parties remain in full compliance.

  5. You are not required to accept this License, since you have not
signed it.  However, nothing else grants you permission to modify or
distribute the Program or its derivative works.  These actions are
prohibited by law if you do not accept this License.  Therefore, by
modifying or distributing the Program (or any work based on the
Program), you indicate your acceptance of this License to do so, and
all its terms and conditions for copying, distributing or modifying
the Program or works based on it.

  6. Each time you redistribute the Program (or any work based on the
Program), the recipient automatically receives a license from the
original licensor to copy, distribute or modify the Program subject to
these terms and conditions.  You may not impose any further
restrictions on the recipients' exercise of the rights granted herein.
You are not responsible for enforcing compliance by third parties to
this License.

  7. If, as a consequence of a court judgment or allegation of patent
infringement or for any other reason (not limited to patent issues),
conditions are imposed on you (whether by court order, agreement or
otherwise) that contradict the conditions of this License, they do not
excuse you from the conditions of this License.  If you cannot
distribute so as to satisfy simultaneously your obligations under this
License and any other pertinent obligations, then as a consequence you
may not distribute the Program at all.  For example, if a patent
license would not permit royalty-free redistribution of the Program by
all those who receive copies directly or indirectly through you, then
the only way you could satisfy both it and this License would be to
refrain entirely from distribution of the Program.

If any portion of this section is held invalid or unenforceable under
any particular circumstance, the balance of the section is intended to
apply and the section as a whole is intended to apply in other
circumstances.

It is not the purpose of this section to induce you to infringe any
patents or other property right claims or to contest validity of any
such claims; this section has the sole purpose of protecting the
integrity of the free software distribution system, which is
implemented by public license practices.  Many people have made
generous contributions to the wide range of software distributed
through that system in reliance on consistent application of that
system; it is up to the author/donor to decide if he or she is willing
to distribute software through any other system and a licensee cannot
impose that choice.

This section is intended to make thoroughly clear what is believed to
be a consequence of the rest of this License.

  8. If the distribution and/or use of the Program is restricted in
certain countries either by patents or by copyrighted interfaces, the
original copyright holder who places the Program under this License
may add an explicit geographical distribution limitation excluding
those countries, so that distribution is permitted only in or among
countries not thus excluded.  In such case, this License incorporates
the limitation as if written in the body of this License.

  9. The Free Software Foundation may publish revised and/or new versions
of the General Public License from time to time.  Such new versions will
be similar in spirit to the present version, but may differ in detail to
address new problems or concerns.

Each version is given a distinguishing version number.  If the Program
specifies a version number of this License which applies to it and "any
later version", you have the option of following the terms and conditions
either of that version or of any later version published by the Free
Software Foundation.  If the Program does not specify a version number of
this License, you may choose any version ever published by the Free Software
Foundation.

  10. If you wish to incorporate parts of the Program into other free
programs whose distribution conditions are different, write to the author
to ask for permission.  For software which is copyrighted by the Free
Software Foundation, write to the Free Software Foundation; we sometimes
make exceptions for this.  Our decision will be guided by the two goals
of preserving the free status of all derivatives of our free software and
of promoting the sharing and reuse of software generally.

                            NO WARRANTY

  11. BECAUSE THE PROGRAM IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW.  EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED
OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.  THE ENTIRE RISK AS
TO THE QUALITY AND PERFORMANCE OF THE PROGRAM IS WITH YOU.  SHOULD THE
PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL NECESSARY SERVICING,
REPAIR OR CORRECTION.

  12. IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE PROGRAM AS PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES,
INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING
OUT OF THE USE OR INABILITY TO USE THE PROGRAM (INCLUDING BUT NOT LIMITED
TO LOSS OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY
YOU OR THIRD PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER
PROGRAMS), EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGES.

                     END OF TERMS AND CONDITIONS

            How to Apply These Terms to Your New Programs

  If you develop a new program, and you want it to be of the greatest
possible use to the public, the best way to achieve this is to make it
free software which everyone can redistribute and change under these terms.

  To do so, attach the following notices to the program.  It is safest
to attach them to the start of each source file to most effectively
convey the exclusion of warranty; and each file should have at least
the "copyright" line and a pointer to where the full notice is found.

    {description}
    Copyright (C) {year}  {fullname}

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with this program; if not, write to the Free Software Foundation, Inc.,
    51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

Also add information on how to contact you by electronic and paper mail.

If the program is interactive, make it output a short notice like this
when it starts in an interactive mode:

    Gnomovision version 69, Copyright (C) year name of author
    Gnomovision comes with ABSOLUTELY NO WARRANTY; for details type `show w'.
    This is free software, and you are welcome to redistribute it
    under certain conditions; type `show c' for details.

The hypothetical commands `show w' and `show c' should show the appropriate
parts of the General Public License.  Of course, the commands you use may
be called something other than `show w' and `show c'; they could even be
mouse-clicks or menu items--whatever suits your program.

You should also get your employer (if you work as a programmer) or your
school, if any, to sign a "copyright disclaimer" for the program, if
necessary.  Here is a sample; alter the names:

  Yoyodyne, Inc., hereby disclaims all copyright interest in the program
  `Gnomovision' (which makes passes at compilers) written by James Hacker.

  {signature of Ty Coon}, 1 April 1989
  Ty Coon, President of Vice

This General Public License does not permit incorporating your program into
proprietary programs.  If your program is a subroutine library, you may
consider it more useful to permit linking proprietary applications with the
library.  If this is what you want to do, use the GNU Lesser General
Public License instead of this License.


# end("license");

