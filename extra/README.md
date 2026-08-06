The build-8.3.sh script in this directory can be used as shortcut to building custom XCP-ng 8.3 ISO images.

Note that it is sensitive to the current working directory, so call it from the root of the repository.

This doesn't replace the official documentation at the root of this project.

It's only tested in a `xcp-ng-build-env` container for XCP-ng 8.3, with external repositories enabled (there's a CLI switch for that when you start the container).

The container can be made suitable for running the script by installing dependencies as follows:

```
sudo yum install -y genisoimage syslinux grub-tools createrepo_c libfaketime
# Optionally, for signing repo metadata inside the ISO image
sudo yum install -y --enablerepo=epel gnupg1
```
