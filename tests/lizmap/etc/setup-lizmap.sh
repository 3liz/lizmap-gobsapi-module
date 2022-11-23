#!/usr/bin/env sh

# For lizmap 3.6+

echo "Set repositories and users rights if needed"
echo "Set view project"
cd /www/lizmap

php console.php acl2:add __anonymous "lizmap.repositories.view" gobsapi
php console.php acl2:add users "lizmap.repositories.view" gobsapi
php console.php acl2:add admins "lizmap.repositories.view" gobsapi

echo "Display WMS links"
php console.php acl2:add __anonymous "lizmap.tools.displayGetCapabilitiesLinks" gobsapi
php console.php acl2:add users "lizmap.tools.displayGetCapabilitiesLinks" gobsapi
php console.php acl2:add admins "lizmap.tools.displayGetCapabilitiesLinks" gobsapi

echo "Edition"
php console.php acl2:add __anonymous "lizmap.tools.edition.use" gobsapi
php console.php acl2:add users "lizmap.tools.edition.use" gobsapi
php console.php acl2:add admins "lizmap.tools.edition.use" gobsapi

echo "Export layers"
php console.php acl2:add __anonymous "lizmap.tools.layer.export" gobsapi
php console.php acl2:add users "lizmap.tools.layer.export" gobsapi
php console.php acl2:add admins "lizmap.tools.layer.export" gobsapi

echo "Add GobsAPI users"
php console.php jcommunity:user:create -v --no-error-if-exist --admin gobsapi_writer al@al.al al_password
php console.php jcommunity:user:create -v --no-error-if-exist gobsapi_reader bob@bob.bob bob_password
php console.php jcommunity:user:create -v --no-error-if-exist gobsapi_writer_filtered md@md.md md_password

echo "Add GobsAPI groups"
php console.php acl2group:create gobsapi_group "GobsAPI group"
php console.php acl2group:create gobsapi_global_group "GobsAPI global group"
php console.php acl2group:create gobsapi_filtered_group "GobsAPI filtered group"

echo "Put users in their groups"
php console.php acl2user:addgroup gobsapi_reader gobsapi_group
php console.php acl2user:addgroup gobsapi_writer gobsapi_group
php console.php acl2user:addgroup gobsapi_writer_filtered gobsapi_group
php console.php acl2user:addgroup gobsapi_reader gobsapi_global_group
php console.php acl2user:addgroup gobsapi_writer gobsapi_global_group
php console.php acl2user:addgroup gobsapi_writer_filtered gobsapi_filtered_group

php console.php acl2:add gobsapi_group "lizmap.repositories.view" "gobsapi"


