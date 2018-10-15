{% from "docker/map.jinja" import docker with context %}

{% set docker_pkg_name = docker.pkg.old_name if docker.use_old_repo else docker.pkg.name %}
{% set docker_pkg_version = docker.version | default(docker.pkg.version) %}
include:
  - .kernel
  - .repo

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
      {% if docker.kernel.pkgs is defined %}
        {% for pkg in docker.kernel.pkgs %}
        - {{ pkg }}
        {% endfor %}
      {% endif %}
    - unless: test "`uname`" = "Darwin"

docker package:
  pkg.installed:
    - name: {{ docker_pkg_name }}
    - version: {{ docker_pkg_version }}
    - refresh: {{ docker.refresh_repo }}
    - require:
      - pkg: docker package dependencies
      {%- if grains['os']|lower not in ('amazon', 'fedora', 'suse',) %}
      - pkgrepo: docker package repository
      {%- endif %}
    - refresh: {{ docker.refresh_repo }}
    - require:
      - pkg: docker package dependencies
      {%- if grains['os']|lower not in ('amazon', 'fedora', 'suse',) %}
      - pkgrepo: docker package repository
      {%- endif %}
    - require_in:

docker-config:
{%- if init_system == "upstart" %}
  file.managed:
    - name: {{ docker.configfile }}
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
{%- else %}
  file.managed:
    - name: /etc/docker/daemon.json
    - source: salt://docker/files/daemon_overlay2.json
    - template: jinja
    - mode: 644
    - user: root
    - makedirs: True
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
    - name: {{ docker.pip.pkgname }}

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
    {%- if docker.proxy %}
    - proxy: {{ docker.proxy }}
    {%- endif %}
{% endif %}
