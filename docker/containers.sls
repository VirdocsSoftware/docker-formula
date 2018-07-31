{% from "docker/map.jinja" import containers with context %}

include:
  - docker

docker-pull-script:
  file.managed:
    - name: /root/docker-pull.sh
    - source: salt://docker/files/docker-pull.sh
    - mode: 755

{% for name, container in containers.items() %}
docker-image-{{ name }}:
  cmd.run:
    - name: /root/docker-pull.sh {{ container.image }}
    - stateful: True
    - require:
      - service: docker-service
      - file: docker-pull-script

docker-image-{{ name }}-retry:
  cmd.run:
    - name: sleep 20 && docker pull {{ container.image }}
    - onfail:
      - cmd: docker-image-{{ name }}

{# TODO: SysV init script #}
{%- set init_system = salt["cmd.run"]("bash -c 'ps -p1 | grep -q systemd && echo systemd || echo upstart'") %}

docker-container-startup-config-{{ name }}:
  file.managed:
{%- if init_system == "systemd" and grains['project'] == "redshelf-dock" and grains['roles'] == "ftp" %}
    - name: /etc/systemd/system/docker-{{ name }}.service
    - source: salt://docker/files/systemd_processor.conf
{%- elif init_system == "systemd" %}
    - name: /etc/systemd/system/docker-{{ name }}.service
    - source: salt://docker/files/systemd.conf
{%- elif init_system == "upstart" %}
    - name: /etc/init/docker-{{ name }}.conf
    - source: salt://docker/files/upstart.conf
{%- endif %}
    - mode: 700
    - user: root
    - template: jinja
    - defaults:
        name: {{ name | json }}
        container: {{ container | json }}
    - require:
      - cmd: docker-image-{{ name }}
{%- if init_system == "systemd" %}        
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: docker-container-startup-config-{{ name }}
      - cmd: docker-image-{{ name }}
{%- endif %}

docker-container-service-{{ name }}:
  service.running:
    - name: docker-{{ name }}
    - enable: True
    - watch:
{%- if init_system == "systemd" %}
      - module: docker-container-startup-config-{{ name }}
{%- elif init_system == "upstart" %}
      - file: docker-container-startup-config-{{ name }}
{%- endif %}
{% endfor %}
