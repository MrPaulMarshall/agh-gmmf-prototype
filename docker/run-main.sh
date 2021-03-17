#!/bin/bash
main_class="$1"
shift
unset ZONE_ID
java -cp app.jar -Dapp.config_path=config/config.json -Dloader.main="$main_class" org.springframework.boot.loader.PropertiesLauncher "$@"
