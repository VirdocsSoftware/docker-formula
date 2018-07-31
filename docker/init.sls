{% from "docker/map.jinja" import docker with context %}
{% if docker.kernel is defined %}
include:
  - .kernel
{% endif %}

{%- set init_system = salt["cmd.run"]("bash -c 'ps -p1 | grep -q systemd && echo systemd || echo upstart'") %}
{%- set docker_ssd = salt["cmd.run"]("bash -c '(lsblk | grep -o nvme1n1) || (lsblk | grep -o xvdb)'") %}

docker package dependencies:
  pkg.installed:
    - pkgs:
      {%- if grains['os_family']|lower == 'debian' %}
      - apt-transport-https
      - python-apt
      {%- endif %}
      - iptables
      - ca-certificates

{%- if grains['os_family']|lower == 'debian' %}
{%- if grains["oscodename"]|lower == 'jessie' and "version" not in docker%}
docker package repository:
  pkgrepo.managed:
    - name: deb http://http.debian.net/debian jessie-backports main
{%- else %}
  {%- if "version" in docker %}
    {%- if (docker.version|string).startswith('1.7.') %}
      {%- set use_old_repo = docker.version < '1.7.1' %}
    {%- else %}
      {%- set version_major = (docker.version|string).split('.')[0]|int %}
      {%- set version_minor = (docker.version|string).split('.')[1]|int %}
      {%- set old_repo_major = 1 %}
      {%- set old_repo_minor = 7 %}
      {%- set use_old_repo = (version_major < old_repo_major or (version_major == old_repo_major and version_minor < old_repo_minor)) %}
    {%- endif %}
  {%- endif %}

{%- if "version" in docker and use_old_repo %}
docker package repository:
  pkgrepo.managed:
    - name: deb https://get.docker.com/ubuntu docker main
    - humanname: Old Docker Package Repository
    - keyid: d8576a8ba88d21e9
{%- else %}
purge old packages:
  pkgrepo.absent:
    - name: deb https://get.docker.com/ubuntu docker main
  pkg.purged:
    - pkgs: 
      - lxc-docker*
      - docker.io*
    - require_in:
      - pkgrepo: docker package repository

docker package repository:
  pkgrepo.managed:
    - name: deb [arch=amd64] https://download.docker.com/linux/ubuntu {{ grains["oscodename"] }} stable
    - humanname: {{ grains["os"] }} {{ grains["oscodename"]|capitalize }} Docker Package Repository
    - keyid: 7EA0A9C3F273FCD8
{%- endif %}
    - keyserver: hkp://p80.pool.sks-keyservers.net:80
    - file: /etc/apt/sources.list.d/docker.list
    - refresh_db: True
{%- endif %}

{%- elif grains['os_family']|lower == 'redhat' and grains['os']|lower != 'amazon' %}
docker package repository:
  pkgrepo.managed:
    - name: docker
    - baseurl: https://yum.dockerproject.org/repo/main/centos/$releasever/
    - gpgcheck: 1
    - gpgkey: https://yum.dockerproject.org/gpg
    - require_in:
      - pkg: docker package
    - require:
      - pkg: docker package dependencies
{%- endif %}

docker package:
  {%- if "version" in docker %}
  pkg.installed:
    {%- if grains["oscodename"]|lower == 'jessie' and "version" not in docker %}
    - name: docker.io
    - version: {{ docker.version }}
    {%- elif use_old_repo %}
    - name: lxc-docker-{{ docker.version }}
    {%- else %}
    {%- if grains['os']|lower == 'amazon' %}
    - name: docker
    {%- else %}
    - name: docker-ce
    {%- endif %}
    - version: {{ docker.version }}
    {%- endif %}
    - hold: True
  {%- else %}
  pkg.latest:
    {%- if grains["oscodename"]|lower == 'jessie' and "version" not in docker %}
    - name: docker.io
    {%- else %}
    {%- if grains['os']|lower == 'amazon' %}
    - name: docker
    {%- else %}
    - name: docker-ce
    {%- endif %}
    {%- endif %}
  {%- endif %}
    - refresh: {{ docker.refresh_repo }}
    - require:
      - pkg: docker package dependencies
      {%- if grains['os']|lower != 'amazon' %}
      - pkgrepo: docker package repository
      {%- endif %}
      - file: docker-config


docker-config:
{%- if init_system == "upstart" %}
  file.managed:
    - name: /etc/default/docker
    - source: salt://docker/files/config
    - template: jinja
    - mode: 644
    - user: root
    - makedirs: True
{%- elif grains['project'] == "jenkins" and grains['roles'] == "slave" %}
  file.managed:
    - name: /etc/docker/daemon.json
    - source: salt://docker/files/daemon_jenkins.json
    - template: jinja
    - mode: 644
    - user: root
    - makedirs: True
{%- elif init_system == "systemd" and grains['project'] != "jenkins" and grains['roles'] != "slave" %}
  file.managed:
    - name: /etc/docker/daemon.json
    - source: salt://docker/files/daemon_devicemapper.json
    - template: jinja
    - mode: 644
    - user: root
    - makedirs: True
    - require:
      - cmd: pvcreate
      - cmd: vgcreate
      - cmd: lvcreate-1
      - cmd: lvcreate-2
      - cmd: lvconvert
      - file: docker-thinpool-profile
      - cmd: lvchange
      - cmd: lvs
      - cmd: cleanup-docker
{%- endif %}      

{%- if init_system == "systemd" and grains['project'] != "jenkins" and grains['roles'] != "slave" %}
{%- if docker_ssd == "xvdb" %}
pvcreate:
  cmd.run:
    - name: pvcreate /dev/xvdb
    - unless: pvdisplay | grep xvdb
vgcreate:
  cmd.run:
    - name: vgcreate docker /dev/xvdb
    - unless: vgdisplay | grep docker
    - require:
      - cmd: pvcreate
{%- elif docker_ssd == "nvme1n1" %}
pvcreate:
  cmd.run:
    - name: pvcreate /dev/nvme1n1
    - unless: pvdisplay | grep nvme1n1
vgcreate:
  cmd.run:
    - name: vgcreate docker /dev/nvme1n1
    - unless: vgdisplay | grep docker
    - require:
      - cmd: pvcreate
{%- endif %}

lvcreate-1:
  cmd.run:
    - name: lvcreate --wipesignatures y -n thinpool docker -l 95%VG || echo "already created"
    - require:
      - cmd: vgcreate

lvcreate-2:
  cmd.run:
    - name: lvcreate --wipesignatures y -n thinpoolmeta docker -l 1%VG || echo "already created"
    - require:
      - cmd: lvcreate-1

lvconvert:
  cmd.run: 
    - name: lvconvert -y --zero n -c 512K --thinpool docker/thinpool --poolmetadata docker/thinpoolmeta || echo "already created"
    - require:
      - cmd: lvcreate-2

docker-thinpool-profile:
  file.managed:
    - name: /etc/lvm/profile/docker-thinpool.profile
    - source: salt://docker/files/docker-thinpool.profile
    - makedirs: True
    - require:
      - cmd: lvconvert

lvchange:
  cmd.run:
    - name: lvchange --metadataprofile docker-thinpool docker/thinpool"
    - unless: lvdisplay | grep metadata
    - require:
      - file: docker-thinpool-profile

lvs:
  cmd.run:
    - name: lvs -o+seg_monitor
    - require:
      - file: docker-thinpool-profile

cleanup-docker:
  cmd.run:
    - name: rm -rf /var/lib/docker && mkdir /var/lib/docker && touch /root/directlvm_created
    - unless: test -e /root/directlvm_created
    - require:
      - cmd: lvs

{%- endif %}      
    

docker-service:
  service.running:
    - name: docker
    - enable: True
    - watch:
    {%- if init_system == "upstart" %}
      - file: /etc/default/docker
    {%- elif init_system == "systemd" %}
      - file: /etc/docker/daemon.json
    {%- endif %}
      - pkg: docker package
    {% if "process_signature" in docker %}
    - sig: {{ docker.process_signature }}
    {% endif %}


{% if docker.install_docker_py %}
docker-py requirements:
  pkg.installed:
    - name: {{ docker.python_pip_package }}
  pip.installed:
    {%- if "pip" in docker and "version" in docker.pip %}
    - name: pip {{ docker.pip.version }}
    {%- else %}
    - name: pip
    - upgrade: True
    {%- endif %}

docker-py:
  pip.installed:
    {%- if "python_package" in docker %}
    - name: {{ docker.python_package }}
    {%- elif "pip_version" in docker %}
    - name: docker-py {{ docker.pip_version }}
    {%- else %}
    - name: docker-py
    {%- endif %}
    - reload_modules: true
{% endif %}
