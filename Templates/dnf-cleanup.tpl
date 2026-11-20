	dnf clean all && \
	rm -rf \
		/var/cache/dnf \
		/var/cache/yum \
		/var/log/dnf.log \
		/var/log/dnf.librepo.log \
		/var/log/dnf.rpm.log \
		/var/log/hawkey.log \
		/var/log/yum.log \
		/tmp/* \
		/var/tmp/*
