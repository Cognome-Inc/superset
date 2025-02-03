#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

######################################################################
# Node stage to deal with static asset construction
######################################################################
ARG PY_VER=3.10-slim-bookworm

# if BUILDPLATFORM is null, set it to 'amd64' (or leave as is otherwise).
ARG BUILDPLATFORM=${BUILDPLATFORM:-amd64}
FROM --platform=${BUILDPLATFORM} node:20-bullseye-slim AS superset-node

ARG NPM_BUILD_CMD="build"

# Include translations in the final build. The default supports en only to
# reduce complexity and weight for those only using en
ARG BUILD_TRANSLATIONS="false"

# Install system dependencies required for node-gyp
RUN --mount=type=bind,source=./docker,target=/docker \
    /docker/apt-install.sh build-essential python3 zstd

ARG DEV_MODE="false"

# Include headless browsers? Allows for alerts, reports & thumbnails, but bloats the images
ARG INCLUDE_CHROMIUM="true"
ARG INCLUDE_FIREFOX="false"

ARG DEPLOYMENT_MODE="local"

# Somehow we need python3 + build-essential on this side of the house to install node-gyp
RUN apt-get update -qq \
    && apt-get install \
        -yqq --no-install-recommends \
        build-essential \
        python3 \
        zstd

ENV BUILD_CMD=${NPM_BUILD_CMD} \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
# NPM ci first, as to NOT invalidate previous steps except for when package.json changes

# Run the frontend memory monitoring script
RUN --mount=type=bind,source=./docker,target=/docker \
    /docker/frontend-mem-nag.sh

WORKDIR /app/superset-frontend


# Create necessary folders to avoid errors in subsequent steps
RUN mkdir -p /app/superset/static/assets \
             /app/superset/translations \

# Creating empty folders to avoid errors when running COPY later on
RUN if [ "$DEPLOYMENT_MODE" = "local" ]; then \
  npm config set ca ""; \
  npm config set strict-ssl false -g; \
  npm config set strict-ssl false; \
fi


RUN --mount=type=bind,target=./package.json,src=./superset-frontend/package.json \
    --mount=type=bind,target=./package-lock.json,src=./superset-frontend/package-lock.json \
    if [ "$DEV_MODE" = "false" ] && [ "$DEPLOYMENT_MODE" = "local" ]; then \
       npm config set ca ""; \
        npm config set strict-ssl false -g; \
        npm config set strict-ssl false; \
        npm ci; \
    else \
        echo "Skipping 'npm ci' in dev mode"; \
    fi

# Runs the webpack build process
COPY superset-frontend /app/superset-frontend


# Copy translation files
COPY superset/translations /app/superset/translations

# Build the frontend if not in dev mode
RUN if [ "$DEV_MODE" = "false" ]; then \
        BUILD_TRANSLATIONS=$BUILD_TRANSLATIONS npm run ${BUILD_CMD}; \
    else \
        echo "Skipping 'npm run ${BUILD_CMD}' in dev mode"; \
    fi

# Compile .json files from .po translations (if required) and clean up .po files
RUN if [ "$BUILD_TRANSLATIONS" = "true" ]; then \
        npm run build-translation; \
    else \
        echo "Skipping translations as requested by build flag"; \
    fi \
	# removing translations files regardless
    && rm -rf /app/superset/translations/*/LC_MESSAGES/*.po \
              /app/superset/translations/messages.pot


# Transition to Python base image
FROM python:${PY_VER} AS python-base
RUN pip install --no-cache-dir --upgrade setuptools pip uv

######################################################################
# Final lean image...
######################################################################
FROM python-base AS lean

# Build argument for including translations
ARG BUILD_TRANSLATIONS="false"

WORKDIR /app
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SUPERSET_ENV=production \
    FLASK_APP="superset.app:create_app()" \
    PYTHONPATH="/app/pythonpath" \
    SUPERSET_HOME="/app/superset_home" \
    SUPERSET_PORT=8088

# Set up necessary directories and user
RUN --mount=type=bind,source=./docker,target=/docker \
    mkdir -p ${PYTHONPATH} \
      superset/static \
      requirements \
      superset-frontend \
      apache_superset.egg-info \
      requirements \
    && useradd --user-group -d ${SUPERSET_HOME} -m --no-log-init --shell /bin/bash superset \
    && /docker/apt-install.sh \
        curl \
        libsasl2-dev \
        libsasl2-modules-gssapi-mit \
        libpq-dev \
        libecpg-dev \
        libldap2-dev \
    && touch superset/static/version_info.json \
    && chown -R superset:superset ./* \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Copy required files for Python build
COPY --chown=superset:superset pyproject.toml setup.py MANIFEST.in README.md ./
COPY --chown=superset:superset superset-frontend/package.json superset-frontend/
COPY --chown=superset:superset requirements/base.txt requirements/
COPY --chown=superset:superset scripts/check-env.py scripts/

# Install Python dependencies using docker/pip-install.sh
RUN --mount=type=bind,source=./docker,target=/docker \
    --mount=type=cache,target=/root/.cache/pip \
    /docker/pip-install.sh --requires-build-essential -r requirements/base.txt

# Copy the compiled frontend assets from the node image
COPY --chown=superset:superset --from=superset-node /app/superset/static/assets superset/static/assets
#copying custom styles to docker image.
COPY --chown=superset:superset ./superset/static/assets/cognome_custom_styles.css ./superset/static/assets/cognome_custom_styles.css

# Copy the main Superset source code
COPY --chown=superset:superset superset superset

# Install Superset itself using docker/pip-install.sh
RUN --mount=type=bind,source=./docker,target=/docker \
    --mount=type=cache,target=/root/.cache/pip \
    /docker/pip-install.sh -e .

# Copy .json translations from the node image
COPY --chown=superset:superset --from=superset-node /app/superset/translations superset/translations

# Compile backend translations and clean up
COPY ./scripts/translations/generate_mo_files.sh ./scripts/translations/
RUN if [ "$BUILD_TRANSLATIONS" = "true" ]; then \
        ./scripts/translations/generate_mo_files.sh \
        && chown -R superset:superset superset/translations; \
    fi \
    && rm -rf superset/translations/messages.pot \
              superset/translations/*/LC_MESSAGES/*.po

COPY --chmod=755 ./docker/run-server.sh /usr/bin/
USER superset

HEALTHCHECK CMD curl -f "http://localhost:${SUPERSET_PORT}/health"

EXPOSE ${SUPERSET_PORT}
CMD ["/usr/bin/run-server.sh"]

######################################################################
# Dev image...
######################################################################
FROM lean AS dev

USER root

# Install dev dependencies
RUN --mount=type=bind,source=./docker,target=/docker \
    /docker/apt-install.sh \
        libnss3 \
        libdbus-glib-1-2 \
        libgtk-3-0 \
        libx11-xcb1 \
        libasound2 \
        libxtst6 \
        git \
        pkg-config \
        && rm -rf /var/lib/apt/lists/*

RUN --mount=type=cache,target=/root/.cache/pip \
    uv pip install --system playwright \
    && playwright install-deps

RUN if [ "$INCLUDE_CHROMIUM" = "true" ]; then \
        playwright install chromium; \
    else \
        echo "Skipping Chromium installation in dev mode"; \
    fi

# Install GeckoDriver WebDriver
ARG GECKODRIVER_VERSION=v0.34.0 \
    FIREFOX_VERSION=125.0.3

RUN if [ "$INCLUDE_FIREFOX" = "true" ]; then \
        apt-get update -qq \
        && apt-get install -yqq --no-install-recommends wget bzip2 \
        && wget -q https://github.com/mozilla/geckodriver/releases/download/${GECKODRIVER_VERSION}/geckodriver-${GECKODRIVER_VERSION}-linux64.tar.gz -O - | tar xfz - -C /usr/local/bin \
        && wget -q https://download-installer.cdn.mozilla.net/pub/firefox/releases/${FIREFOX_VERSION}/linux-x86_64/en-US/firefox-${FIREFOX_VERSION}.tar.bz2 -O - | tar xfj - -C /opt \
        && ln -s /opt/firefox/firefox /usr/local/bin/firefox \
        && apt-get autoremove -yqq --purge wget bzip2 && rm -rf /var/[log,tmp]/* /tmp/* /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    else \
        echo "Skipping Firefox installation in dev mode"; \
    fi

# Install MySQL client dependencies
RUN --mount=type=bind,source=./docker,target=/docker \
    /docker/apt-install.sh default-libmysqlclient-dev

# Copy development requirements and install them
COPY --chown=superset:superset requirements/development.txt requirements/
RUN --mount=type=bind,source=./docker,target=/docker \
    --mount=type=cache,target=/root/.cache/pip \
    /docker/pip-install.sh --requires-build-essential -r requirements/development.txt

USER superset
######################################################################
# CI image...
######################################################################
FROM lean AS ci

COPY --chown=superset:superset --chmod=755 ./docker/*.sh /app/docker/

CMD ["/app/docker/docker-ci.sh"]
