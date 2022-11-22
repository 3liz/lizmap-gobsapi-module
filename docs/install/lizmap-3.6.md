# Installation for Lizmap 3.6+


## Lizmap Web Client gobsapi module

NB: all the path given are relative to your Lizmap Web Client instance folder.

### installing source code from a zip

Copy the `gobsapi` directory inside the `lizmap/lizmap-modules/` of a working
Lizmap Web Client instance to have a new `lizmap/lizmap-modules/gobsapi/` folder
containing the files `module.xml`, `events.xml`, and folders.

### installing source code with Composer

If you have Composer (the package manager for PHP), `lizmap/my-packages/` and 
create the composer.json file if it does not exist:

```bash
cp lizmap/my-packages/composer.json.dist lizmap/my-packages/composer.json
```

Then declare the package of the gobsapi module:

```bash
composer --working-dir=lizmap/my-packages/ require "lizmap/lizmap-gobsapi-module"
```

### Run the Lizmap Web Client installer

* Enable the module by running the configurator of lizmap

```bash
php lizmap/install/configurator.php gobsapi
```

* Then you need to run the Lizmap installer

```bash
lizmap/install/set_rights.sh
lizmap/install/clean_vartmp.sh
php lizmap/install/installer.php
```

## Authentication driver

If your Lizmap Web Client uses **SAMLv2** to authenticate the users,
you need to force the `gobsapi` module to use another driver.
The `SAML` protocol is based on URL redirections, which are not suitable for the G-Obs API end point.

In the file `lizmap/var/config/gobsapi/config.ini.php`, set these parameters:

```ini
[coordplugins]
auth="gobsapi/auth.coord.ini.php"
saml=0
[coordplugin_auth]
driver=db
```

And create the file `lizmap/var/config/gobsapi/auth.coord.ini.php`, containing:

```ini
;<?php die(''); ?>
;for security reasons , don't remove or modify the first line
driver=Db
session_name=JELIX_USER
secure_with_ip=0
timeout=0
auth_required=off
on_error=2
error_message="jcommunity~login.error.notlogged"
on_error_action="jcommunity~login:out"
bad_ip_action="jcommunity~login:out"
on_error_sleep=0
after_login="view~default:index"
after_logout="jcommunity~login:index"
enable_after_login_override=on
enable_after_logout_override=on
persistant_enable=on
persistant_cookie_name=LizmapSession
persistant_duration=1
password_hash_method=1
password_hash_options=

[Db]
dao="lizmap~user"
profile=jauth
password_crypt_function=sha1
form="lizmap~account_admin"
userform="lizmap~account"
uploadsDirectory=
```


