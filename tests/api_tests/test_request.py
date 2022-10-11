#! /usr/bin/env python

import json
import unittest
from datetime import datetime, timedelta
from pathlib import Path

import requests


class TestRequests(unittest.TestCase):
    # noinspection PyPep8Naming
    def __init__(self, methodName="runTest"):
        super().__init__(methodName)

        self.base_url = 'http://localhost:9095/gobsapi.php/'
        self.api_token = None

    def getHeader(self, content_type=None, token=None, request_sync_date=None, last_sync_date=None) -> dict:
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

        if method == 'get':
            response = requests.get(url, params=params, headers=headers)
        elif method in ('post', 'put'):
            # We must send data read from the data_file path
            json_content = None
            files_content = None
            file_mode = 'r'
            if content_type == 'multipart/form-data':
                file_mode = 'rb'
            with open(Path(__file__).parent.absolute() / data_file, mode=file_mode) as source_file:
                if content_type == 'application/json':
                    json_content = json.load(source_file)
                elif content_type == 'multipart/form-data':
                    files_content = {'mediaFile': source_file}
                    # requests will pass the correct content type
                    # it should NOT be set in the api call
                    del headers['Content-Type']
                if method == 'post':
                    response = requests.post(
                        url, params=params, headers=headers,
                        json=json_content, files=files_content
                    )
                elif method == 'put':
                    response = requests.put(
                        url, params=params, headers=headers,
                        json=json_content, files=files_content
                    )
        elif method == 'delete':
            response = requests.delete(url, params=params, headers=headers)
        else:
            response = requests.get(url, params=params, headers=headers)

        # Log response text to ease debugging
        print(response.text)

        # Status code
        self.assertEqual(response.status_code, expected_status_code)

        # Compare the JSON contained in the test_file
        # to the request text response
        if test_file:
            if expected_format in ('dict', 'list', 'text'):
                with open(Path(__file__).parent.absolute() / test_file) as expected_file:
                    if expected_format == 'text':
                        self.assertEqual(response.text, expected_file.read())
                    else:
                        expected_content = json.load(expected_file)
                        received_content = json.loads(response.text)
                        if expected_format == 'dict':
                            self.assertDictEqual(received_content, expected_content)
                        elif expected_format == 'list':
                            self.assertListEqual(received_content, expected_content)
            elif expected_format == 'binary':
                with open(Path(__file__).parent.absolute() / test_file, mode='rb') as expected_file:
                    self.assertEqual(response.content, expected_file.read())

        # Return the reponse
        return response

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

    def test_project_geopackage(self):
        """ Get the Geopackage of a project """
        project_key = 'gobsapi~gobsapi'
        self.api_call(
            entry_point=f'/project/{project_key}/geopackage',
            test_file='data/output_project_geopackage.gpkg',
            expected_format='binary'
        )

    def test_indicator_details(self):
        """ Get details of the indicator """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}',
            test_file='data/output_indicator_details.json',
        )

    def test_observation_create_without_id_and_spatial_object(self):
        """ Create an observation """
        # We do not ask the api_call to check the JSON response against the file
        # So that we can do it manually
        # Since the result of the call contains dynamically generated data
        # such as id, created_at, update_at, etc.
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method='post',
            content_type='application/json',
            data_file='data/input_observation_create.json',
            test_file=None,
        )

        # Check the data is not empty
        self.assertTrue(len(response.text))

        # Check the returned observation contains expected data
        json_response = json.loads(response.text)
        expected_content = 'data/input_observation_create.json'
        fields_equals = [
            'indicator', 'start_timestamp', 'end_timestamp',
            'coordinates', 'wkt', 'values',
            'media_url'
        ]
        with open(Path(__file__).parent.absolute() / expected_content) as f:
            expected_data = json.load(f)
            for field in fields_equals:
                expected = expected_data[field]
                received = json_response[field]
                if isinstance(expected, str):
                    self.assertEqual(received, expected)
                elif isinstance(expected, dict):
                    self.assertDictEqual(received, expected)
                    self.assertEqual(received, expected)
                elif isinstance(expected, list):
                    self.assertListEqual(received, expected)
                else:
                    self.assertEqual(received, expected)
        # Check UID is valid
        observation_uuid = json_response['uuid']
        self.assertTrue(self.is_valid_uuid(observation_uuid))

        # Check created_at and updated_at
        # BEWARE: the test stack PostgreSQL timezone is in UTC !!!
        # DO NOT USE THIS UNTIL PostgreSQL SERVER IS IN UTC
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
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/deletedObservations',
            last_sync_date=last_sync_date,
            test_file=None,
            expected_format='list'
        )
        json_response = json.loads(response.text)
        self.assertEqual(json_response, [observation_uuid])

    def test_indicator_document(self):
        """ Get an indicator document by uid """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        document_uid = '1a7f7323-6b18-46ed-a9fe-9efbe1f006a2'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/document/{document_uid}',
            test_file='data/output_indicator_document_text_file.txt',
            expected_format='text',
        )

    def test_indicator_preview(self):
        """ Get an indicator document by uid """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        document_uid = '542aa72f-d1de-4810-97bb-208f2388698b'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/document/{document_uid}',
            test_file='data/output_indicator_document_preview.jpg',
            expected_format='binary'
        )

    def test_indicator_observations_all(self):
        """ Get observations of the indicator population """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'population'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observations',
            test_file=None,
            expected_format='list',
        )
        json_response = json.loads(response.text)
        self.assertEqual(len(json_response), 44)

    def test_indicator_observation_detail(self):
        """ Get an observation of the indicator hiker_position """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        observation_uuid = '1adae0cf-0f3b-4af5-bf26-e72c7fde24f2'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file='data/output_observation_details.json',
            expected_format='dict',
        )

    def test_observation_update(self):
        """ Create an observation & test media upload, download, deletion """
        # Create a new observation
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method='post',
            content_type='application/json',
            data_file='data/input_observation_create.json',
            test_file=None,
        )

        # Check the data is not empty
        self.assertTrue(len(response.text))

        # Check UID is valid
        json_response = json.loads(response.text)
        observation_id = json_response['id']
        observation_uuid = json_response['uuid']
        self.assertTrue(self.is_valid_uuid(observation_uuid))

        # Update this observation
        # Uid must be replace in the template file
        data_file = 'data/input_observation_update.json'
        dynamic_update_file_path = 'data/input_observation_update_DYNAMIC.json'
        with open(Path(__file__).parent.absolute() / data_file, mode='r') as source_file:
            with open(Path(__file__).parent.absolute() / dynamic_update_file_path, mode='w') as dynamic_file:
                # Update the newly created observation id and uuid in the JSON content
                json_content = json.load(source_file)
                json_content['id'] = observation_id
                json_content['uuid'] = observation_uuid
                json.dump(json_content, dynamic_file)

        # Send update requests with this new JSON file
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method='put',
            content_type='application/json',
            data_file=dynamic_update_file_path,
            test_file=None,
        )

        # Get observation back
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            expected_format='dict',
        )
        observation = json.loads(response.text)

        # Check modified data are OK
        self.assertDictEqual(observation['coordinates'], {"x": -3.791, "y": 48.33})
        self.assertEqual(observation['wkt'], 'POINT(-3.791 48.33)')
        self.assertListEqual(observation['values'], [45])

        # Delete file
        (Path(__file__).parent.absolute() / dynamic_update_file_path).unlink()

        # Delete this observation to be idempotent
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            method='delete',
            expected_format='dict'
        )

    def test_observation_media_actions(self):
        """ Create an observation & test media upload, download, deletion """
        # Create a new observation
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'hiker_position'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method='post',
            content_type='application/json',
            data_file='data/input_observation_create.json',
            test_file=None,
        )
        # Check the data is not empty
        self.assertTrue(len(response.text))

        # Check UID is valid
        json_response = json.loads(response.text)
        observation_uuid = json_response['uuid']
        self.assertTrue(self.is_valid_uuid(observation_uuid))

        # Upload a media file
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}/uploadMedia',
            method='post',
            content_type='multipart/form-data',
            data_file='data/input_observation_media_file.jpg',
            test_file='data/output_observation_upload_media_success.json',
        )

        # Get observation back with the URL
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            expected_format='dict',
        )
        observation = json.loads(response.text)
        expected_url = f'{self.base_url }project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}/media'
        self.assertEqual(observation['media_url'], expected_url)

        # Delete the media
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}/deleteMedia',
            method='delete',
            test_file='data/output_observation_delete_media_success.json',
            expected_format='dict',
        )

        # Delete this observation to be idempotent
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            method='delete',
            expected_format='dict'
        )


if __name__ == "__main__":
    unittest.main()
