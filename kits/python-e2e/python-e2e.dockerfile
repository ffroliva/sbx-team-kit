# syntax=docker/dockerfile:1
# Python + Playwright + ffmpeg baked into the shell-docker template, so a test run downloads no interpreter and no browser.
ARG BASE_IMAGE=docker/sandbox-templates:shell-docker
FROM ${BASE_IMAGE}
ARG UV_VERSION
ARG PYTHON_VERSIONS
ARG PLAYWRIGHT_VERSION
USER root
# Shared, read-only locations: every sandbox user finds the same interpreters and browser build.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_PYTHON_PREFERENCE=only-managed \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN set -eux; \
    curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh; \
    uv --version | grep -q "${UV_VERSION}"
RUN set -eux; uv python install ${PYTHON_VERSIONS}; for v in ${PYTHON_VERSIONS}; do uv python find "$v"; done
# The browser build is tied to the Playwright package version: a project whose lock pins another version downloads again.
RUN set -eux; \
    first="${PYTHON_VERSIONS%% *}"; \
    uv tool run --python "$first" --from "playwright==${PLAYWRIGHT_VERSION}" playwright install --with-deps chromium; \
    apt-get install -y --no-install-recommends ffmpeg; ffmpeg -version | head -1; \
    rm -rf /root/.cache/uv /var/lib/apt/lists/*; \
    chmod -R a+rX /opt/uv /opt/ms-playwright; \
    echo "${PLAYWRIGHT_VERSION}" > /opt/ms-playwright/PLAYWRIGHT_VERSION
USER agent
ENTRYPOINT ["bash"]
CMD ["-l"]
