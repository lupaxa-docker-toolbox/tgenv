	apt-get -y autoremove && \
	apt-get clean && \
	rm -rf \
		/var/lib/apt/lists/* \
		/var/cache/apt/archives/* \
		/var/cache/apt/*.bin \
		/var/log/apt/* \
		/var/log/dpkg.log \
		/tmp/* \
		/var/tmp/*
