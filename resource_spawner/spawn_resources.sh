#!/bin/bash
trap  "_finish" 0 1 2 3 9 15

## Function to cleanup the files and sub processes
function _finish() {
  rv=${1:-$?};
  pkill -9 -P $$
#  destroyResources
#  kill 0
  rm -fr /dev/shm/lines.$$ /dev/shm/number.$$
  exit $rv
}


### Creates resources on overcloud
function createResourcesOnOverCloud() {
  lg Creating Resources on overcloud
  export OS_NO_CACHE='true'
  export OS_USERNAME=admin
  export OS_TENANT_NAME='admin'
  export OS_PASSWORD='Chang3M3'
  export OS_AUTH_URL=https://${project}.jiocloud.com:5000/v2.0
  export OS_AUTH_STRATEGY='keystone'
  export OS_REGION_NAME='TestCloud'
  export CINDER_ENDPOINT_TYPE='publicURL'
  export GLANCE_ENDPOINT_TYPE='publicURL'
  export KEYSTONE_ENDPOINT_TYPE='publicURL'
  export NOVA_ENDPOINT_TYPE='publicURL'
  export NEUTRON_ENDPOINT_TYPE='publicURL'
  lg Creating Tenant - demo
  [ `keystone tenant-get demo 2> /dev/null | grep -c "enabled\s*|\s*True"` -eq 0 ] && keystone tenant-create --name demo;
  lg Creating user demo with _member_ role in tenant demo
  [ `keystone user-get demo 2> /dev/null | grep -c "enabled\s*|\s*True"` -eq 0 ] && keystone user-create --name demo --pass demo;
  [ `keystone user-role-list --user demo --tenant demo 2> /dev/null | grep -c _member_` -eq 0 ] && keystone user-role-add --user demo --role _member_ --tenant demo;
  [ `keystone user-role-list --user admin --tenant demo 2> /dev/null | grep -c admin` -eq 0 ] && keystone user-role-add --user admin --role admin --tenant demo;
  lg Creating Images
  if [ `glance image-show ubuntu-12.04 2> /dev/null | grep -c "status\s*|\s*active"` -eq 0 ]; then
    curl http://10.135.96.60/vm_images/ubuntu-12.04-server-cloudimg-amd64-disk1.img > $tmp/12.04.img
    glance image-create --name ubuntu-12.04 --disk-format qcow2 --container-format bare --is-public True < $tmp/12.04.img
    rm -f $tmp/12.04.img
  fi
  if [ `glance image-show ubuntu-14.04 | grep -c "status\s*|\s*active"` -eq 0 ]; then
    curl http://10.135.96.60/vm_images/trusty-server-cloudimg-amd64-disk1.img> $tmp/14.04.img
    glance image-create --name ubuntu-14.04 --disk-format qcow2 --container-format bare --is-public True < $tmp/14.04.img
    rm -f $tmp/14.04.img
  fi

  export OS_TENANT_NAME='demo'
  lg Creating Network in demo tenant - demo-network
  [ `neutron net-show demo-network | grep -ic "status\s*|\s*ACTIVE"` -eq 0 ] && neutron net-create demo-network ;
  if [ $create_ipam -eq 1 ]; then
    lg Creating IPAM demo-ipam
    [ `neutron ipam-list | grep -c demo-ipam` -eq 0 ] && neutron ipam-create demo-ipam
  fi
  lg Creating subnet demo-subnet with cidr 10.1.0.0/24
  [ `neutron subnet-list | grep -c 10.1.0.0/24` -eq 0 ] && neutron subnet-create demo-network 10.1.0.0/24 --name demo-subnet ;
  imagelist=`glance image-list | awk '/qcow2/ {print $2}'`
  netid=`neutron net-show demo-network | awk '/\| *id/ { print $4}'`
  echo "__Returns__: image_list: `echo $imagelist`, netid: $netid"
}


### Forks as sub processes,
## Check the vm console using nova-console and rebuild the vm if it stuck on boot.
## There was some situations where vm boot stuck on cloud-init, this function will fix that situation
function check_boot() {
  lg Checking the state of $1
  num_check=${2:-0}
  vm_state=0
  print_started=0
  if [ $1 == "ct1" ]; then
    check_duration=30
  else
    check_duration=10
  fi
  while [ $vm_state == 0 ]; do
    sleep $check_duration
    vm_state=`nova list --name $1 | grep -c ACTIVE`
  done
  if [ $1 == "ct1" ]; then
    lg $1 is booting normally
    return 0
  fi
  lg Booted $1, Checking console
  userdata_started=0
  userdata_finished=0
  while [ $num_check -lt 60 ]; do
    num_check=$(($num_check+1))
    sleep 10
    if [ $userdata_started -eq 0 ]; then
      if [ `echo $num_check | grep -c "[246]0"` -ne 0 ]; then
        lg $1 boot seems to be hung, rebuilding the server
        nova rebuild $1 ubuntu12.04 > /dev/null
        check_boot $1 
      fi
      userdata_started=`nova console-log $1 | grep -c "Starting userdata execution"`
    elif [ $userdata_finished -eq 0 ]; then
      [ $print_started -eq 0 ] && echo "`date` $1 Userdata execution Started" && print_started=1
      if [ `echo $num_check | grep -c "[4567]0"` -ne 0 ]; then
        lg $1: userdata execution taking longer than expected
#        nova rebuild $1 ubuntu12.04 > /dev/null
#        check_boot $1 
      fi
      userdata_finished=`nova console-log $1 | grep -c "Finished userdata execution"`
    else 
      [ $print_started -eq 0 ] && echo "`date` Userdata execution Started" && print_started=1
	lg $1 is booting normally
        exit 0
    fi
  done
  exit 0
}

function lg() {
  echo "`date`|$*"
}



function usage() { 
  printf "\n$*\n"
  printf "Usage: $0 -u <user name> [-v] [-t <tenant>] [-P <overcloud admin password> ] [-R <overcloud region> [-c <number of compute nodes>] [-s <number of storage nodes>] [-p <password>] [ -l ] [ -d ] [-B <Version>] [-T <version>] \n\n-u <user name>\t User name who have admin access to admin project\n-c <number of compute nodes>\tNumber of compute nodes to be spawned, default is 3\n-s <number of storage nodes>\tNumber of storage nodes to be spawned, default 3\n-t <tenant>\tTenant to be used (default is testproj_<pid>)\n-p <password>\tuser password\n-l\tUse datacenter internal floating IP, default is public floating IP\n-d\t Delete project and all components in it,\n-v\tVerbose output\n-B <version>\tBase snapshot version\n-T <version>\tTarget snapshot version\n-R <overcloud Region>\t Overcloud Region name\n-P <overcloud admin/service user password>\tOvercloud admin and service user password" 
  exit 0
}

function rebuildServers() {
  lg Rebuilding All servers
  for node in `nova list | awk '{print $4}'| grep -v "Name\|^ *$"`; do  
    nova rebuild $node ubuntu12.04 > /dev/null
    check_boot $node
  done
}

function destroyResources() {
  export OS_TENANT_NAME="$project"
  nova keypair-delete $project > /dev/null ||  _fail "Kepair deletion failed for $project"
  pkill -9 -P $$
  lg "Deleting VMs"
  for nd in `nova list | awk '{print $2}' | grep -v "ID\|^ *$"`; do 
    lg Deleting VM $nd
    nova delete $nd;
  done
  sleep 5;
  while [ `nova list | awk '{print $2}' | grep -v "ID\|^ *$" | wc -l` -ne 0 ]; do
    sleep 3;
  done
  sleep 3
  lg "Deleting the Networks"
  neutron net-delete stg_access || _retry 1 neutron net-delete stg_access
  neutron net-delete stg_cluster || _retry 1 neutron net-delete stg_cluster
  neutron net-delete sdn || _retry neutron 1 net-delete sdn
  fip_id=`neutron floatingip-list | grep "[0-9\.][0-9\.]" | awk '{print $2}'`
  if [ `echo $fip_id | grep -c "[a-z]"` -ne 0 ]; then
    neutron floatingip-disassociate $fip_id || _retry 1 neutron floatingip-disassociate $fip_id
    neutron floatingip-delete $fip_id || _retry 1 neutron floatingip-delete $fip_id
  fi
  neutron ipam-delete ipam1 || _retry 1 neutron ipam-delete ipam1
  export OS_TENANT_NAME="admin"
  tid=`keystone tenant-get $project | awk '/id/ {print $4}'`
  glance member-delete 3f855d6f-c054-4d51-add0-41a96122b13a $tid
  for flavor in m1.controller m1.compute m1.contrail m1.storage; do
    nova flavor-access-remove $flavor $tid > /dev/null
  done
  keystone tenant-delete $project
  lg "Deleted the tenant $project"
  exit
}

function _retry() {
  echo ; return
  retry_num=${1:-1}
  shift
  command=$*
  max_retry=5
  lg Warn $command failed, retrying
  while [ $retry_num -le $max_retry ]; do
    $command || _retry $retry_num $command
  done
}

function _fail() {
  lg $*, Rolling back.
#  _finish 100
  # TODO do not leave this uncommented!!!
#  destroyResources
  exit 100
}

# download Puppet content
function setupPuppet() {
  pushd ../
  apt-get install -y ruby1.9.1 rubygems
  gem install --no-ri --no-rdoc librarian-puppet-simple
  librarian-puppet install
  popd
}

function setupHiera() {
  pushd ../
  if [ -f hiera/user.yaml ]; then
    cp hiera/user.yaml{,.save}
  fi
  echo '' > hiera/user.yaml
  addHieraData target_version $target_version
  addHieraData project $project
  popd
}

function addHieraData() {
  pushd ../
  echo "$1: $2" >> hiera/user.yaml
  popd
}

function createResources() {
  lg "Generate key and export it to openstack"
  ### Generate key and export it.
  ssh-keygen -f $tmp/id_rsa -t rsa -N ''
  nova keypair-add --pub-key $tmp/id_rsa.pub $project > /dev/null ||  _fail "Kepair addition failed for $project"

  # TODO There is an issue with flavor creation
  # the commands to list/show flavors do not work on Havana,
  # therefor, we are ignoring failures when we try to create
  # flavors. This is obviously problematic for cases where
  # there are unexpected failures, but this should rarely happen
  # (b/c the flavors only need to be created once on each tenant)
  for flavor in m1.controller m1.compute m1.contrail m1.storage; do
    lg Adding flavor $flavor
    if [ $flavor == 'm1.controller' ]; then
      mem=4096; disk=20; swap=2048; vcpu=4
    elif [ $flavor == 'm1.compute' ]; then
      mem=8192;  disk=20; swap=4096; vcpu=8; ephemeral="--ephemeral 500"
    elif [ $flavor == 'm1.contrail' ]; then
      mem=8192;  disk=20; swap=4096; vcpu=4
    elif [ $flavor == 'm1.storage' ]; then
      mem=2048; disk=20; swap=1048; vcpu=4; ephemeral="--ephemeral 50"
    fi
    lg  Creating flavor $flavor
    nova flavor-create $flavor $flavor $mem $disk $vcpu --swap $swap --is-public=false $ephemeral > /dev/null || true
  done

  # I am pretty sure this is no longer needed
  #glance member-create 3f855d6f-c054-4d51-add0-41a96122b13a $tid

  proj_synced=0;
  num_try=1;
  failed_sync=0;

  lg "Creating Networks"

  sdn_net="sdn_${project}"
  stg_access_net="stg_access_${project}"
  stg_cluster_net="stg_cluster_${project}"

  neutron net-create $sdn_net > /dev/null ||  _fail Network creation $sdn_net  failed
  neutron net-create $stg_access_net > /dev/null ||  _fail Network creation $stg_access_net failed
  neutron net-create $stg_cluster_net > /dev/null ||  _fail Network creation $stg_cluster_net failed
  if [ $create_ipam -eq 1 ]; then
    lg "Creating IPAM ipam1"
    # TODO check if it exists, and just warn
    neutron ipam-create ipam1 > /dev/null ||  _fail IPAM create failed
  fi
  lg Creating Subnets
  # TODO maybe we want to make the subnets configurable eventually...
  neutron subnet-create $sdn_net 10.0.0.0/24 > /dev/null ||  _fail subnet create sdn failed
  neutron subnet-create $stg_access_net 10.1.0.0/24 > /dev/null ||  _fail subnet create stg_access failed
  neutron subnet-create $stg_cluster_net 10.2.0.0/24 > /dev/null ||  _fail subnet create stg_cluster failed
  stg_cluster_nw_id=`neutron net-list | grep $stg_cluster_net | awk '{print $2}'`
  stg_access_nw_id=`neutron net-list | grep $stg_access_net | awk '{print $2}'`
  sdn_nw_id=`neutron net-list | grep $sdn_net | awk '{print $2}'`
  lg Booting VMs
  ct1_name="ct1_$project"
  db1_name="db1_${project}"
  st1_name="st1_${project}"
  st2_name="st2_${project}"
  st3_name="st3_${project}"
  oc1_name="oc1_${project}"
  oc2_name="oc2_${project}"
  lb1_name="lb1_${project}"
  if [ $contrail_fresh_vm -eq 0 ]; then
    lg Booting contrail VM
    # TODO move the specification of networks and ip addresses to an external
    # config file
    nova boot --flavor m1.medium --image 3f855d6f-c054-4d51-add0-41a96122b13a --meta host_type=ct $ct1_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.245 > /dev/null ||  _fail nova boot $ct1_name failed.
  else
    nova boot --flavor m1.contrail --image ubuntu12.04 --key-name $project  --meta host_type=ct $ct1_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.245 > /dev/null ||  _fail nova boot $ct1_name failed.
    check_boot $ct1_name &
  fi

  nova boot --flavor m1.controller --image ubuntu12.04 --key-name $project  --meta host_type=db $db1_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.10 > /dev/null ||  _fail nova boot $db1_name failed
  check_boot $db1_name &
  nova boot --flavor m1.storage --image ubuntu12.04 --key-name $project  --meta host_type=st $st1_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.51 --nic net-id=${stg_cluster_nw_id},v4-fixed-ip=10.2.0.51 > /dev/null ||  _fail nova boot $st1_name failed

  check_boot $st1_name &
  nova boot --flavor m1.storage --image ubuntu12.04 --key-name $project  --meta host_type=st $st2_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.52 --nic net-id=${stg_cluster_nw_id},v4-fixed-ip=10.2.0.52 > /dev/null ||  _fail nova boot $st2_name failed

  check_boot $st2_name &
  nova boot --flavor m1.storage --image ubuntu12.04 --key-name $project  --meta host_type=st $st3_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.53 --nic net-id=${stg_cluster_nw_id},v4-fixed-ip=10.2.0.53 > /dev/null ||  _fail nova boot $st3_name
  check_boot $st3_name
  nova boot --flavor m1.controller --image ubuntu12.04 --key-name $project  --meta host_type=oc $oc1_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.11 > /dev/null ||  _fail nova boot $oc1_name failed
  check_boot $oc1_name &
  nova boot --flavor m1.controller --image ubuntu12.04 --key-name $project  --meta host_type=oc $oc2_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.12 > /dev/null ||  _fail nova boot $oc2_name failed
  check_boot $oc2_name &


  for num in `seq $num_cp`; do
    nova boot --flavor m1.compute --image ubuntu12.04 --key-name $project  --meta host_type=cp "cp${num}_${project}" --nic net-id=${sdn_nw_id} --nic net-id=${stg_access_nw_id} > /dev/null ||  _fail nova boot "cp${num}_${project}" failed
    check_boot cp$num &
  done

  for num in `seq $num_st`; do
    if [ $num -gt 3 ]; then
      nova boot --flavor m1.storage --image ubuntu12.04 --key-name $project --meta host_type=st "st${num}_${project}"  --nic net-id=${stg_access_nw_id} --nic net-id=${stg_cluster_nw_id} > /dev/null ||  _fail nova boot "st${num}_${project}" failed
      che "st${num}_${project}" &
    fi
  done
  lg Creating Floating IP
  if [ $local -eq 1 ]; then
    neutron floatingip-create local-public > /dev/null; rv=$?
    if [ $rv -ne 0 ]; then
      neutron floatingip-create local-public > /dev/null ||  _fail floatingip-create failed
    fi
  else
    neutron floatingip-create jio-access > /dev/null ; rv=$?
    if [ $rv -ne 0 ]; then
      neutron floatingip-create jio-access > /dev/null ||  _fail floatingip-create failed
    fi
  fi

  fip_id=`neutron floatingip-list | grep "[0-9\.][0-9\.]" | awk '{print $2}'`
  fip=`nova floating-ip-list | awk '/[0-9][0-9\.]*/ {print $2}'`
  #lb1_id=`nova list| grep lb1 | awk '{print $2}'`
  lb1_port_id=`neutron  port-list | grep '"10.1.0.5"' | awk '{print $2}'`
  lg Associating floating IP $fip to lb1
  neutron floatingip-associate $fip_id $lb1_port_id > /dev/null ||  _fail floatingip associate $fip failed
  lg Adding security group rules to enable access using floating IP
  neutron security-group-rule-create --direction ingress --protocol tcp default > /dev/null ||  _fail security group rule creation failed
  neutron security-group-rule-create --direction ingress --protocol udp default > /dev/null ||  _fail security group rule creation failed
  neutron security-group-rule-create --direction ingress --protocol icmp default > /dev/null ||  _fail security group rule creation failed
  neutron security-group-rule-create --direction egress --protocol icmp default > /dev/null ||  _fail security group rule creation failed
  neutron security-group-rule-create --direction egress --protocol tcp default > /dev/null ||  _fail security group rule creation failed
  neutron security-group-rule-create --direction egress --protocol udp default > /dev/null ||  _fail security group rule creation failed

  if [ $num_st -gt 3 ]; then
    total_vms=$((7+$num_cp+$num_st-3))
  else
    total_vms=$((7+$num_cp))
  fi
  vms_up=0;
  num_try=1;
  failed=0;
  lg Waiting all cloud systems in active state
  while [ $vms_up -lt $total_vms ]; do
    sleep 10
    nova_list=`nova list`
    vms_up=`echo "$nova_list" | grep -c ACTIVE`
    vms_error=`echo "$nova_list" | grep -c ERROR`
    if [ $vms_error -gt 0 ]; then
	_fail One or more VMs failed to spawn
    fi
    num_try=$(($num_try+1))
    if [ $num_try -gt 300 ]; then
      failed=1
      vms_up=$total_vms
    fi
  done
  if [ $failed -eq 0 ]; then

    nova boot --flavor m1.small --image ubuntu12.04 --key-name $project --meta host_type=lb $lb1_name --nic net-id=${stg_access_nw_id},v4-fixed-ip=10.1.0.5 > /dev/null ||  _fail nova boot $lb1_name failed
    check_boot $lb1_name &

  lb_vm_state=0
  failed_lb_vm_up=0
  num_try=0
  lg waiting for management VM to be up
  while [ $lb_vm_state == 0 ]; do
    sleep 5
    lb_vm_state=`nova list | grep lb_vm1 | grep -c ACTIVE`
    if [ $num_try -gt 40 ]; then
      failed_lb_vm_up=1
      lb_vm_state=1
    fi
  done
#  check_boot lb_vm1 &
  if [ $failed_lb_vm_up -eq 1 ]; then
    lg "ERR...Something went bad.... management vm is not coming up. rolling back"
    _finish 100
  fi

  exit 0

  stopit=0
  failed_fab=0
  num_console=0
  echo 0 > /dev/shm/number.$$
  lb_vm_rebooted=0;
  while [ $stopit -eq 0 ]; do
    sleep 5
    num=`cat /dev/shm/number.$$`
      if [ `echo $ci_started | grep -c "[0-9][0-9]*"` -eq 0 ]; then
        ci_started=`nova console-log lb_vm1 | grep -n "cloud-init start running:" | cut -f1 -d:`
        touch /dev/shm/lines.$$
      else
        [ $num -eq 0 ] && num=$ci_started
        nova console-log lb_vm1 2> /dev/null| tail -n +$num |  tee >( 
        echo $(($num+`wc -l`)) > /dev/shm/number.$$) /dev/shm/lines.$$
        stopit=`grep -c "^ *__SHUTDOWN__ *$\|^ *__FAILED_FAB__ *$" /dev/shm/lines.$$`
        failed_fab=`grep -c "^ *__FAILED_FAB__ *$" /dev/shm/lines.$$`
      fi
    if [ $num_console -gt 500 ];then
       _fail Timeout occured in lb_vm1 boot
    fi
      num_console=$(($num_console+1))
  done
#  [ $failed_fab -ne 0 ] && _fail fab execution failed
  for job in `jobs -p`; do
    wait $job || let "fail+=1"
  done
  if [ "$fail" != "0" ]; then
    _fail one of the checkboot job failed
  fi

### Add /etc/hosts entry
## This is required as the endpoints use https
sudo sed -i -e "/^\s*$fip.*/{s/.*/$fip $project.jiocloud.com/;:a;n;:ba;q}" -e "$ a$fip $project.jiocloud.com" /etc/hosts

### Create resources on overcloud
createResourcesOnOverCloud
#  cat <<EOF
#  Endpoint IP: 		$fip 
#  Number of Compute:	$num_cp
#  Number of Storage:	$num_st
#  Tenant Name:		$project
#EOF
  
  else
    _fail lb_vm1 not coming up
  fi

}

function makeUserDataMgmt() {
  nova_list=`nova list | grep -vi "Name.*Status.*Task.*State\|\-\-\-"`
  fwd_dns=`echo "$nova_list" | awk -F\| '{gsub (/ */,"",$3); print $3","$7}' | sed 's/^\([a-zA_-Z0-9][a-z_A-Z0-9]*\),.*stg_access=\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/update add \1.jiocloud.com.  86400 IN A \2/' | sed ':a;N;$!ba;s/\n/\\\\\\\n/g'`
  rev_dns=`echo "$nova_list" | grep -vi "Name.*Status.*Task.*State\|\-\-\-" | awk -F\| '{gsub (/ */,"",$3); print $3","$7}' | sed 's/^\([a-zA-Z_0-9][a-zA-Z_0-9]*\),.*stg_access=\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).\([0-9][0-9]*\).*/update add \5.\4.\3.\2.in-addr.arpa. 86400 ptr \1.jiocloud.com./' | sed ':a;N;$!ba;s/\n/\\\\\\\n/g'`
#  rev_dns=$(echo "$nova_list" | awk -F\| '{gsub (/ */,"",$3);  print $3","$7}' | sed -e 's/sdn=//g' -e 's/stg_access=//g' -e 's/stg_cluster=//g' -e 's/^\([a-zA-Z_0-9][a-zA-Z_0-9]*\),\s*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).\([0-9][0-9]*\);\s*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).\([0-9][0-9]*\)/update add \5.\4.\3.\2.in-addr.arpa. 86400 ptr \1.jiocloud.com.\\\\nupdate add \9.\8.\7.\6.in-addr.arpa. 86400 ptr \1.jiocloud.com./' -e 's/^\([a-zA-Z_0-9][a-zA-Z_0-9]*\),\s*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).\([0-9][0-9]*\),.*/update add \5.\4.\3.\2.in-addr.arpa. 86400 ptr \1.jiocloud.com./' | sed ':a;N;$!ba;s/\n/\\\\n/g')
#`echo "$nova_list" | awk -F\| '{gsub (/ */,"",$3);  print $3","$7}' | sed -e 's/sdn=//g' -e 's/stg_access=//g' -e 's/stg_cluster=//g' -e 's/^\([a-zA-Z_0-9][a-zA-Z_0-9]*\),\s*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).\([0-9][0-9]*\);\s*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).\([0-9][0-9]*\)/update add \5.\4.\3.\2.in-addr.arpa. 86400 ptr \1.jiocloud.com.\\\\\\\nupdate add \9.\8.\7.\6.in-addr.arp. 86400 ptr \1.jiocloud.com./' -e 's/^\([a-zA-Z_0-9][a-zA-Z_0-9]*\),\s*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).\([0-9][0-9]*\)/update add \5.\4.\3.\2.in-addr.arpa. 86400 ptr \1.jiocloud.com./' | sed ':a;N;$!ba;s/\n/\\\\\\\n/g'`

  cp_nodes=`echo "$nova_list"| awk -F\| '/cp[0-9][0-9]*/ {gsub (/ */,"",$3); print $3","$7}' | sed 's/^\([a-zA-Z0-9][a-zA-Z0-9]*\),.*stg_access=\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/'\''\2'\''/' | awk '{ res=$0"," res } END {gsub (/,$/,"",res); printf res}'`
  st_nodes=`echo "$nova_list" | awk -F\| '/st[0-9][0-9]*/ {gsub (/ */,"",$3); print $3","$7}' | sed 's/^\([a-zA-Z0-9][a-zA-Z0-9]*\),.*stg_access=\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/'\''\2'\''/' | awk '{ res=$0"," res } END {gsub (/,$/,"",res); printf res}'`
  ## Remove ct1 from all_nodes for now, this will be added after puppetizing contrail server
  all_nodes=`echo "$nova_list" |grep -vi "lb_vm1\|ct1" | awk -F\| '{gsub (/ */,"",$3); print $3","$7}' | sed 's/^\([a-z_A-Z0-9][a-z_A-Z0-9]*\),.*stg_access=\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/'\''\2'\''/' | awk '{ res=$0"," res } END {gsub (/,$/,"",res); printf res}'`

  sed -i -e "s/___CP_SERVERS_TOBE_REPLACED_Static___/$cp_nodes/" -e "s/___ST_SERVERS_TOBE_REPLACED_Static___/$st_nodes/" -e "s/___ALL_SERVERS_TOBE_REPLACED_Static___/$all_nodes/" userdata_lb.sh
  sed -i -e "/___SSH_PRIVATE_KEY_Static___/r $tmp/id_rsa" -e "/___SSH_PRIVATE_KEY_Static___/d" userdata_mgmt.sh
  if [ $verbose -eq 1 ]; then
    sed -i -e "s/___PROJECT___/$project/g" -e "s/___Forward_DNS_Entries_Static___/$fwd_dns/g" -e "s/___Reverse__DNS__Entries_Static___/$rev_dns/g" -e "s/__Verbose__/1/" userdata_mgmt.sh
  else
    sed -i -e "s/___PROJECT___/$project/g" -e "s/___Forward_DNS_Entries_Static___/$fwd_dns/g" -e "s/___Reverse__DNS__Entries_Static___/$rev_dns/g" -e "s/__Verbose__/0/" userdata_mgmt.sh
  fi
#[ $target_version -eq 0 ] && usage Target version must be provided
  if [ $base_version -ne 0 ]; then
    sed -i 's/___UPGRADE_TO_BASE_Static___/1/' userdata_mgmt.sh
  else
    sed -i 's/___UPGRADE_TO_BASE_Static___/0/' userdata_mgmt.sh
  fi
}

### Starts here
contrail_fresh_vm=0
delete=0
local=0
num_cp=0
num_st=3
logfile=/tmp/spawn_resource_$$.log
fail=0
verbose=0
nova_rebooted=0
base_version=0
target_version=0
while getopts "giBI:bvdc:s:r:k:t:u:p:lT:P:t:" OPTION; do
  case "${OPTION}" in
    u)
      user=${OPTARG}
      ;;
    p)
      passwd=${OPTARG}
      ;;
    g)
      contrail_fresh_vm=1
      ;;
    l)
      local=1
      ;;
    r)
      region=${OPTARG:-"P1_mum"}
      ;;
    c)
      num_cp=${OPTARG:-3}
      ;;
    s)
      num_st=${OPTARG:-3}
      ;;
    t)
      tenant=${OPTARG}
      ;;
    B)
      base_version=${OPTARG}
      ;;
    T)
      target_version=${OPTARG}
      ;;
    k)
      url=${OPTARG:-'https://identity-beta.jiocloud.com/v2.0/'}
      ;;
    d)
      delete=1
      ;;
    v)
      verbose=1
      ;;
    P)
      overcloud_admin_password=${OPTARG}
      ;;
    R)
      overcloud_region=${OPTARG}
      ;;
    I)
      create_ipam=1
      ;;
    *)
      usage Invalid parameter
      ;;
  esac
done

[ -z $user ] && usage User name must be provided
[ $target_version -eq 0 ] && usage Target version must be provided
if [ -z $tenant ]; then
  usage "Tenant must be provided"
fi

if [ -z $passwd ]; then
  echo -n "Enter password: "
  stty -echo
  read passwd;
  stty echo
fi
project=${tenant:-"testproj_$$"}
overcloud_admin_password=${overcloud_admin_password:-"Chang3M3"}
overcloud_region=${overcloud_region:-"RegionOne"}
url=${url:-'https://identity-beta.jiocloud.com/v2.0/'}
region=${region:-"P1_mum"}
num_cp=${num_cp:-3}
num_st=${num_st:-3}
num_st=3
export OS_NO_CACHE='true'
export OS_USERNAME=$user
export OS_TENANT_NAME=${tenant}
export OS_PASSWORD=$passwd
export OS_AUTH_URL=${url}
export OS_AUTH_STRATEGY='keystone'
export OS_REGION_NAME=${region}
export CINDER_ENDPOINT_TYPE='publicURL'
export GLANCE_ENDPOINT_TYPE='publicURL'
export KEYSTONE_ENDPOINT_TYPE='publicURL'
export NOVA_ENDPOINT_TYPE='publicURL'
export NEUTRON_ENDPOINT_TYPE='publicURL'


echo;
if [ $delete -eq 1 ]; then
  destroyResources
fi
if [ `echo $project | grep -c _` -ne 0 ]; then
  usage "Invalid tenant name \"_\" is not allowed"
fi
export tmp=`mktemp -d /tmp/selfextract.XXXXXX`
tar=`awk '/^__ARCHIVE_STARTS_HERE__/ {print NR + 1; exit 0; }' $0`
tail -n+$tar $0 | tar xz -C $tmp
pwd=`pwd`
setupPuppet
cd $tmp
createResources
cd $pwd
rm -fr $tmp
exit 0
__ARCHIVE_STARTS_HERE__
