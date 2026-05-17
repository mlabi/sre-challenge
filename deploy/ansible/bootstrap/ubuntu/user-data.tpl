autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - @SSH_PUBKEY@
  identity:
    hostname: @HOSTNAME@
    username: labi
    password: "$6$rounds=4096$lab$placeholder.replaceme.with.mkpasswd.output"
  network:
    version: 2
    ethernets:
      any-eth:
        match:
          name: "en*"
        dhcp4: true
  storage:
    layout:
      name: direct
  packages:
    - openssh-server
    - curl
    - ca-certificates
    - gnupg
    - python3
  user-data:
    disable_root: true
  late-commands:
    - echo 'labi ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-labi
    - chmod 440 /target/etc/sudoers.d/90-labi
