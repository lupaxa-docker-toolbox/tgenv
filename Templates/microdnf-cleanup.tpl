	microdnf clean all && \
	rm -rf \
		/var/cache/dnf \
		/var/cache/yum \
		/var/cache/microdnf \
		/var/log/dnf.log \
		/var/log/dnf.librepo.log \
		/var/log/hawkey.log \
		/var/log/yum.log \
		/tmp/* \
		/var/tmp/*
