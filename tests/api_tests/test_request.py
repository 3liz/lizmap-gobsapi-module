#! /usr/bin/env python

import json
import unittest
from datetime import datetime, timedelta

import requests


class TestRequests(unittest.TestCase):
    # noinspection PyPep8Naming
    def __init__(self, methodName="runTest"):
        super().__init__(methodName)

        self.base_url = 'http://localhost:9095/gobsapi.php/'
        self.api_token = None

    def getHeader(self, content_type=None, token=None, request_sync_date=None, last_sync_date=None):
        """ Set request header """
        headers = {
            'Accept': content_type
        }
        if token:
            headers['Authorization'] = 'Bearer {}'.format(token)
        if content_type in ('application/json', 'multipart/form-data'):
            headers['Content-Type'] = content_type

        # Add request sync date and optional last sync date
        if not request_sync_date:
            now = datetime.now()
            request_sync_date = now.strftime("%Y-%m-%d %H:%M:%S")
            headers['requestSyncDate'] = request_sync_date
        if last_sync_date:
            headers['lastSyncDate'] = last_sync_date

        return headers

    def setUp(self) -> None:
        """ Login as admin and set the token """
        self.login('gobsapi_writer', 'al_password')

    def login(self, username='admin', password='admin') -> None:
        """ Login and get token """
        url = 'user/login'
        params = {
            'username': username,
            'password': password,
        }
        headers = self.getHeader(
            content_type='application/json'
        )
        req = requests.get(self.base_url + url, params=params, headers=headers)
        if req.status_code != 200:
            return

        content = json.loads(req.text)
        if 'token' not in content:
            return

        self.api_token = content['token']

    def api_call(
        self, entry_point, test_file, method='get',
        params={}, data_file=None,
        expected_format='dict', expected_status_code=200,
        content_type=None, token_required=True,
        request_sync_date=None, last_sync_date=None
    ):
        """
        Wrapper which test an api call against test data
        """
        if not self.api_token and token_required:
            pass

        # Send request
        url = self.base_url + entry_point
        headers = self.getHeader(
            content_type=content_type,
            token=self.api_token,
            request_sync_date=request_sync_date,
            last_sync_date=last_sync_date
        )
        # files = {'media': open('test.jpg', 'rb')}
        # requests.post(url, files=files)

        if method == 'get':
            req = requests.get(url, params=params, headers=headers)
        elif method == 'post':
            # get data
            data_content = None
            json_content = None
            if data_file:
                with open(data_file) as json_file:
                    file_content = json.load(json_file)
                    if content_type == 'application/json':
                        json_content = file_content
                    else:
                        data_content = file_content
            req = requests.post(url, params=params, headers=headers, data=data_content, json=json_content)
        elif method == 'delete':
            req = requests.delete(url, params=params, headers=headers)
        else:
            req = requests.get(url, params=params, headers=headers)

        print(req.text)
        # {"code":0,"status":"error","message":"The observation media folder does not exist or is not writable"}

        # Status code
        self.assertEqual(req.status_code, expected_status_code)

        # Compare the JSON contained in the test_file
        # to the request text response
        if test_file:
            with open(test_file) as json_file:
                data = json.load(json_file)
                if expected_format == 'dict':
                    self.assertDictEqual(json.loads(req.text), data)
                elif expected_format == 'list':
                    self.assertListEqual(json.loads(req.text), data)
                else:
                    self.assertEqual(json.loads(req.text), data)

        # Return the content
        return req.text

    def is_valid_uuid(self, given_uid):
        """ Check if the uuid is valid """
        if len(given_uid) != 36:
            return False
        if len(given_uid.split('-')) != 5:
            return False

        return True

    def test_user_projects(self):
        """ Get logged user projects """
        self.api_call(
            entry_point='user/projects',
            test_file='data/output_user_projects.json',
            expected_format='list',
        )

    def test_logout(self):
        """ Log out """
        # Logout
        self.api_call(
            entry_point='user/logout',
            test_file='data/output_user_logout.json',
            expected_format='dict',
        )

        # Get user projects -> expects 401
        self.api_call(
            entry_point='user/projects',
            test_file='data/output_access_token_missing.json',
            expected_format='dict',
            expected_status_code=401,
        )

        # Log back in
        self.login('gobsapi_writer', 'al_password')

    def test_project_unknown(self):
        """ Get details of an unexistent project """
        project_key = 'gobsapi~foobar'
        self.api_call(
            entry_point=f'/project/{project_key}',
            test_file='data/output_project_unknown.json',
            expected_format='dict',
            expected_status_code=404,
        )

    def test_project_details(self):
        """ Get details of the gobsapi project """
        project_key = 'gobsapi~gobsapi'
        self.api_call(
            entry_point=f'/project/{project_key}',
            test_file='data/output_project_details.json',
            expected_format='dict'
        )

    def test_project_indicators(self):
        """ Get the project indicators """
        project_key = 'gobsapi~gobsapi'
        self.api_call(
            entry_point=f'/project/{project_key}/indicators',
            test_file='data/output_project_indicators.json',
            expected_format='list'
        )

    def test_indicator_details(self):
        """ Get details of the indicator """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}',
            test_file='data/output_indicator_details.json',
        )

    def test_observation_create_witout_id_and_spatial_object(self):
        """ Create an observation """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        # We do not ask the api_call to check the JSON response against the file
        # So that we can do it manually
        # Since the result of the call contains dynamically generated data
        # such as id, created_at, update_at, etc.
        text_response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method='post',
            content_type='application/json',
            data_file='data/input_observation_create.json',
            test_file=None,
        )
        # Check the data is not empty
        self.assertTrue(len(text_response))

        # Check the returned observation contains expected data
        json_response = json.loads(text_response)
        expected_content = 'data/input_observation_create.json'
        fields_equals = [
            'indicator', 'start_timestamp', 'end_timestamp',
            'coordinates', 'wkt', 'values',
            'media_url'
        ]
        with open(expected_content) as f:
            expected_data = json.load(f)
            for field in fields_equals:
                expected = expected_data[field]
                response = json_response[field]
                if isinstance(expected, str):
                    self.assertEqual(response, expected)
                elif isinstance(expected, dict):
                    self.assertDictEqual(response, expected)
                    self.assertEqual(response, expected)
                elif isinstance(expected, list):
                    self.assertListEqual(response, expected)
                else:
                    self.assertEqual(response, expected)
        # Check UID is valid
        observation_uuid = json_response['uuid']
        self.assertTrue(self.is_valid_uuid(observation_uuid))

        # Check created_at and updated_at
        # BEWARE: the test stack PostgreSQL timezone is in UTC !!!
        # DO NOT USE THIS UNTIL postgresql SERVER IS IN UTC
        # now = datetime.now()
        now = datetime.utcnow()
        now_str = now.strftime("%Y-%m-%d %H:%M")
        created_at = datetime.strptime(json_response['created_at'], "%Y-%m-%d %H:%M:%S")
        updated_at = datetime.strptime(json_response['updated_at'], "%Y-%m-%d %H:%M:%S")
        created_at_str = created_at.strftime("%Y-%m-%d %H:%M")
        updated_at_str = updated_at.strftime("%Y-%m-%d %H:%M")
        self.assertEqual(now_str, created_at_str)
        self.assertEqual(now_str, updated_at_str)

        # Check we create the same observation -> an error must be raised
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method='post',
            content_type='application/json',
            data_file='data/input_observation_create.json',
            test_file=None,
            expected_status_code=400
        )

        # Delete this observation to be idempotent
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            method='delete',
            expected_format='dict'
        )

        # Delete again -> should have a 404
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file='data/output_observation_does_not_exist.json',
            expected_format='dict',
            method='delete',
            expected_status_code=404
        )

        # Get deleted observations since 2 seconds
        # Should have the one above
        delta_seconds = 2
        last_sync_datetime = created_at - timedelta(seconds=delta_seconds)
        last_sync_date = last_sync_datetime.strftime("%Y-%m-%d %H:%M:%S")
        text_response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/deletedObservations',
            last_sync_date=last_sync_date,
            test_file=None,
            expected_format='list'
        )
        json_response = json.loads(text_response)
        self.assertEqual(json_response, [observation_uuid])

    def test_indicator_observations_all(self):
        """ Get observations of the indicator population """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'population'
        text_response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observations',
            test_file=None,
            expected_format='list'
        )
        json_response = json.loads(text_response)
        self.assertEqual(len(json_response), 44)


# TODO
# Get the indicator documents
# Update an existing observation
# Get an observation data
# Upload a media for a given observation
# Delete an observation media
# Download an observation media

if __name__ == "__main__":
    unittest.main()
