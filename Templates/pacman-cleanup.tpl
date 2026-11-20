	pacman -Scc --noconfirm && \
	rm -f /var/lib/pacman/sync/* && \
	rm -rf \
		/var/cache/* \
		/var/log/pacman.log \
		/tmp/* \
		/var/tmp/*
