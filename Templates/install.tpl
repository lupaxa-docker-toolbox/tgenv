	git clone --depth 1 https://github.com/tgenv/tgenv.git /root/.tgenv && \
	printf '%s\n' 'export TGENV_ROOT=/root/.tgenv' 'export PATH="${TGENV_ROOT}/bin:${PATH}"' >> /root/.bashrc && \
