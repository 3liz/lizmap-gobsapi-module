
# Debug

You can activate the **debug mode** by manually editing the configuration file `lizmap/var/config/gobsapi.ini.php`
and modify the variable `log_api_calls' with the `debug` value:

```ini
[gobsapi]
log_api_calls=debug
```

You will then be able to see the API calls log written in the file `lizmap/var/log/messages.log`

```bash
tail -f lizmap/var/log/messages.log
```

Messages will be like

```
2021-02-09 17:18:52	127.0.0.1	default	GOBSAPI - ################
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - path: getProjectByKey
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - input_data: {"projectKey":"lizmapdemo~a_fake_project","module":"gobsapi","action":"project:getProjectByKey"}
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - http_code: 404
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - status: error
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - message: The given project key does not refer to a known project
2021-02-09 17:19:05	127.0.0.1	default	GOBSAPI - ################

```
