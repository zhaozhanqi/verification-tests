#!/bin/bash

export TOOLS_HOME=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

. "$TOOLS_HOME"/common.sh

echo "Installing packages on $(os_type)"
if [ "$(os_type)" == "fedora_dnf" ]; then
    cmd="dnf install -y"
    file="deps.dnf.fedora"
elif [ "$(os_type)" == "fedora" ]; then
    cmd="yum install -y"
    file="deps.yum.fedora"
    additional_deps=install_rvm_if_ruby_is_outdated
    need_bundler_from_gem=1
elif [ "$(os_type)" == "ubuntu" -o "$(os_type)" == "debian" ] || [ "$(os_type)" == "mint" ]; then
    cmd="apt-get install -q --ignore-missing --fix-missing -y"
    file="deps.deb"
    additional_deps=install_rvm_if_ruby_is_outdated
    need_bundler_from_gem=1
elif [ "$(os_type)" == "rhel6" ]; then
    cmd="yum install -y"
    file="deps.yum.RHEL"
    additional_deps=install_rvm_if_ruby_is_outdated
    need_bundler_from_gem = 1
elif [ "$(os_type)" == "rhel7" ] || [ "$(os_type)" == "centos7" ]; then
    cmd="yum install -y"
    file="deps.yum.RHEL7"
    additional_deps=install_rvm_if_ruby_is_outdated
    need_bundler_from_gem=1
elif [ "$(os_type)" == "Mac OS X" ]; then
    cmd="brew install"
    file="deps.macos"
    additional_deps=install_rvm_if_ruby_is_outdated
    need_bundler_from_gem=1
else
    exit 3
fi

cat "${TOOLS_HOME}/os_deps/$file" | grep -v '^\s*#' | xargs $(need_sudo) $cmd
    $additional_deps

# have to do these manually prior to bundler or else hell will break loose
# We need to use 'gem install bundler' beacause for RHEL, using 'yum install rubygem-bundler'
# will install ruby-2.0, which won't work with the rvm ruby stable version
#
#/usr/share/rubygems/rubygems/dependency.rb:296:in `to_specs': Could not find 'bundler' (>= 0) among 11 total gem(s) (Gem::LoadError)
#    from /usr/share/rubygems/rubygems/dependency.rb:307:in `to_spec'
#    from /usr/share/rubygems/rubygems/core_ext/kernel_gem.rb:47:in `gem'
#    from /bin/bundle:22:in `<main>'
if [ -n "$need_bundler_from_gem" ]; then
    gem install bundler
fi
#gem install nokogiri
