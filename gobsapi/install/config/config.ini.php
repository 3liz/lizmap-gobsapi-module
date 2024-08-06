[modules]

ldapdao.enabled=on
ldapdao.localconf=1
multiauth.enabled=off

saml.enabled=off
samladmin.enabled=off
saml.localconf=1
samladmin.localconf=1

gobsapi.enabled=on
gobsapi.localconf=1

[coordplugin_auth]
driver=ldapdao

[coordplugins]
jacl2=1
auth="index/auth.coord.ini.php"

[coordplugin_jacl2]
on_error=2
error_message="jacl2~errors.action.right.needed"
on_error_action="jelix~error:badright"
