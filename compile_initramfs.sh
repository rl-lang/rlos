cd rootfs/ && find . | cpio -o -H newc | gzip > ../initramfs.img && cd ..
