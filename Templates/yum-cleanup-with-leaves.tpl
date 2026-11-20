#	yum remove -y \
#		<package list> \
#		--remove-leaves \
#		&& \
	yum clean all && \
	rm -rf \
		/var/cache/yum \
		/var/log/yum.log \
		/tmp/* \
		/var/tmp/*
