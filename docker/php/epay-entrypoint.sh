#!/bin/sh
set -eu

# Match the official PHP entrypoint's default command and option handling.
if [ "$#" -eq 0 ]; then
    set -- php-fpm
fi
case "$1" in
    -*) set -- php-fpm "$@" ;;
esac

if [ "${1##*/}" = php-fpm ]; then
    prepare_permissions=1
    for arg in "$@"; do
        case "$arg" in
            -t|-tt|--test|-i|--info|-v|--version|-h|--help)
                prepare_permissions=0
                ;;
        esac
    done

    # A bind mount is present only at runtime, so Dockerfile RUN cannot fix it.
    # CLI commands and FPM diagnostics must remain free of permission changes.
    if [ "$prepare_permissions" -eq 1 ]; then
        epay-fix-plugin-permissions
    fi
fi

# Keep the official entrypoint and let FPM receive container signals as PID 1.
exec docker-php-entrypoint "$@"
