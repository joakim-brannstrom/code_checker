FROM ubuntu:focal

# Dependencies:
RUN apt-get update && \
    apt-get -y --no-install-recommends install \
        ca-certificates \
        git \
        gcc g++ \
        make \
        curl \
        xz-utils \
        iwyu \
        clang-tidy \
        libsqlite3-dev

WORKDIR /opt

ARG DMD_VERSION
RUN echo ${DMD_VERSION}

# setup
ENV DC "dmd"
ENV DLANG "./dlang.sh"

RUN curl -S https://dlang.org/install.sh --output ${DLANG}
RUN bash ${DLANG} install dmd-${DMD_VERSION}
RUN echo "#!/bin/bash\nsource $(bash ${DLANG} -a)\nbash -c \"\${@}\"" > /root/myshell.sh
RUN chmod 755 /root/myshell.sh
SHELL ["/root/myshell.sh"]
RUN dmd --version && dub --version

# fix_repo
COPY repo.tar.gz /opt
RUN mkdir repo
RUN tar xfz repo.tar.gz -C repo && rm repo.tar.gz

# build_with_dub
RUN cd repo && dub build
RUN cd repo && dub test
RUN cd repo && dub run -c integration_test
