<p align="center">
  <a href="https://github.com/lupaxa-docker-toolbox">
    <img src="https://raw.githubusercontent.com/the-lupaxa-project/brand-assets/master/logos/organisations/docker-toolbox/readme-logo.png" alt="The Lupaxa Project: Docker Toolbox" />
  </a>
</p>

<h1 align="center">Tgenv</h1>

Tgenv is a set of images with [tgenv](https://github.com/tgenv/tgenv) installed. Each image can install and switch Terragrunt versions.

The supported tags are the releases still in the vendor's own security support, the same set [Container Framework](https://github.com/lupaxa-docker-toolbox/container-framework) builds.

Debian and Ubuntu also publish the codename. The newest tag of each family is `latest`.

Generating a version asks [Version Helper](https://github.com/lupaxa-docker-toolbox/version-helper) for the pinned package line, then the image build clones tgenv.

## Requirements

Docker and Python 3. Version Helper runs inside the base image while generating, so Docker has to be able to pull it.

## Usage

From the repository root, a family directory, or a version directory:

```shell
./manage-all.sh --generate
./manage-all.sh --build
./manage-all.sh --generate --build --clean
./manage-all.sh --publish
./manage-all.sh --publish --ghcr
```

A version directory has `manage.sh` instead of `manage-all.sh`. The flags are the same. The newest version of a family also publishes `latest`.

```text
-h, --help       Show the help
-d, --debug      Trace the script
-g, --generate   Write the Dockerfile
-b, --build      Build the image
-c, --clean      Build without the cache
-p, --publish    Push the image
-G, --ghcr       Push to GHCR instead of Docker Hub
-l, --latest     Also tag latest
-t, --tags       Extra publish tag, repeatable
```

`--publish` pushes to Docker Hub. `--ghcr` pushes to GHCR. The machine has to be logged in to that registry.

A stable tag `vX.Y.Z` runs Generate Release. That workflow builds every image and pushes it to Docker Hub and GHCR. Docker Hub uses `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. GHCR uses the workflow token.

A package created by that workflow takes this repository's public visibility.

A release candidate `vX.Y.Z-rcN` runs Generate Test Release. That workflow builds every image and does not push it.

## Image Names

The local name is `tgenv-<os>-<version>` with dots written as dashes, for example `tgenv-alpine-3-24`.

Docker Hub uses `lupaxa/tgenv-<os>:<version>`, for example `lupaxa/tgenv-alpine:3.24`. GHCR uses `ghcr.io/lupaxa-docker-toolbox/tgenv-<os>:<version>`.

`Config/packages.cfg` lists bash, curl, git, unzip, and the certificate package. Those let the image download a Terragrunt release. The finished image starts bash.

<a href="https://github.com/the-lupaxa-project">
    <img src="https://raw.githubusercontent.com/the-lupaxa-project/brand-assets/master/logos/components/footer-for-child-orgs.svg" alt="The Lupaxa Project Footer" width="100%" />
</a>
