#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh
source terraform-exports/terraform-${base_os}-exports.sh

check_param base_os
check_param aws_access_key_id
check_param aws_secret_access_key
check_param private_key_data
check_param region_name
check_param AWS_NETWORK_CIDR
check_param AWS_NETWORK_GATEWAY
check_param PRIVATE_DIRECTOR_STATIC_IP
check_param SUBNET_ID
check_param AVAILABILITY_ZONE
check_param DIRECTOR
check_param SECURITY_GROUP_NAME

source /etc/profile.d/chruby.sh
chruby 2.1.2

semver=`cat version-semver/number`
cpi_release_name=bosh-aws-cpi
working_dir=$PWD
manifest_dir="${working_dir}/director-state-file"
manifest_filename=${manifest_dir}/${base_os}-director-manifest.yml

mkdir -p $manifest_dir/keys
echo "$private_key_data" > $manifest_dir/keys/bats.pem
eval $(ssh-agent)
chmod go-r $manifest_dir/keys/bats.pem
ssh-add $manifest_dir/keys/bats.pem

#create director manifest as heredoc
cat > "${manifest_filename}"<<EOF
---
name: bosh

releases:
- name: bosh
  url: file://tmp/bosh-release.tgz
- name: bosh-aws-cpi
  url: file://tmp/bosh-aws-cpi.tgz

networks:
- name: private
  type: manual
  subnets:
  - range:    ${AWS_NETWORK_CIDR}
    gateway:  ${AWS_NETWORK_GATEWAY}
    dns:      [8.8.8.8]
    cloud_properties: {subnet: $SUBNET_ID}
- name: public
  type: vip

resource_pools:
- name: default
  network: private
  stemcell:
    url: file://tmp/stemcell.tgz
  cloud_properties:
    instance_type: m3.xlarge
    availability_zone: $AVAILABILITY_ZONE
    ephemeral_disk:
      size: 25000
      type: gp2

disk_pools:
- name: default
  disk_size: 25_000
  cloud_properties: {type: gp2}

jobs:
- name: bosh
  templates:
  - {name: nats, release: bosh}
  - {name: redis, release: bosh}
  - {name: postgres, release: bosh}
  - {name: blobstore, release: bosh}
  - {name: director, release: bosh}
  - {name: health_monitor, release: bosh}
  - {name: registry, release: bosh}
  - {name: cpi, release: bosh-aws-cpi}

  instances: 1
  resource_pool: default
  persistent_disk_pool: default

  networks:
  - name: private
    static_ips: [$PRIVATE_DIRECTOR_STATIC_IP]
    default: [dns, gateway]
  - name: public
    static_ips: [$DIRECTOR]

  properties:
    nats:
      address: 127.0.0.1
      user: nats
      password: nats-password

    redis:
      listen_addresss: 127.0.0.1
      address: 127.0.0.1
      password: redis-password

    postgres: &db
      host: 127.0.0.1
      user: postgres
      password: postgres-password
      database: bosh
      adapter: postgres

    # Tells the Director/agents how to contact registry
    registry:
      address: $PRIVATE_DIRECTOR_STATIC_IP
      host: $PRIVATE_DIRECTOR_STATIC_IP
      db: *db
      http: {user: admin, password: admin, port: 25777}
      username: admin
      password: admin
      port: 25777

    # Tells the Director/agents how to contact blobstore
    blobstore:
      address: $PRIVATE_DIRECTOR_STATIC_IP
      port: 25250
      provider: dav
      director: {user: director, password: director-password}
      agent: {user: agent, password: agent-password}

    director:
      address: 127.0.0.1
      name: micro
      db: *db
      cpi_job: cpi

    hm:
      http: {user: hm, password: hm-password}
      director_account: {user: admin, password: admin}

    aws: &aws
      access_key_id: $aws_access_key_id
      secret_access_key: $aws_secret_access_key
      default_key_name: "bats"
      default_security_groups: [$SECURITY_GROUP_NAME]
      region: "${region_name}"

    # Tells agents how to contact nats
    agent: {mbus: "nats://nats:nats-password@$PRIVATE_DIRECTOR_STATIC_IP:4222"}

    ntp: &ntp
    - 0.north-america.pool.ntp.org
    - 1.north-america.pool.ntp.org

cloud_provider:
  template: {name: cpi, release: bosh-aws-cpi}

  # Tells bosh-micro how to SSH into deployed VM
  ssh_tunnel:
    host: $DIRECTOR
    port: 22
    user: vcap
    private_key: $manifest_dir/keys/bats.pem

  # Tells bosh-micro how to contact remote agent
  mbus: https://mbus-user:mbus-password@$DIRECTOR:6868

  properties:
    aws: *aws

    # Tells CPI how agent should listen for requests
    agent: {mbus: "https://mbus-user:mbus-password@0.0.0.0:6868"}

    blobstore:
      provider: local
      path: /var/vcap/micro_bosh/data/cache

    ntp: *ntp
EOF

echo "normalizing paths to match values referenced in $manifest_filename"
# manifest paths are now relative so the tmp inputs need to be updated
mkdir ${manifest_dir}/tmp
cp ./bosh-cpi-dev-artifacts/${cpi_release_name}-${semver}.tgz ${manifest_dir}/tmp/${cpi_release_name}.tgz
cp ./bosh-release/release.tgz ${manifest_dir}/tmp/bosh-release.tgz
cp ./stemcell/stemcell.tgz ${manifest_dir}/tmp/stemcell.tgz

initver=$(cat bosh-init/version)
initexe="$PWD/bosh-init/bosh-init-${initver}-linux-amd64"
chmod +x $initexe

echo "using bosh-init CLI version..."
$initexe version

echo "deleting existing BOSH Director VM..."
$initexe delete ${manifest_filename}

echo "deploying BOSH..."
$initexe deploy $manifest_filename
