#!/bin/sh
ln -sf $(nix-build metac.nix -A sftpServer --no-out-link)/bin/sftp-server build/metac-sftp-server
#ln -sf $(nix-build metac.nix -A sshfs --no-out-link)/bin/sshfs build/metac-sshfs

tigervnc=$(nix-build metac.nix -A tigervnc --no-out-link)
for i in vncviewer x0vncserver; do
    ln -sf $tigervnc/bin/$i build/$i
done
