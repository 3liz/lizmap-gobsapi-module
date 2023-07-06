#! /usr/bin/env python

import json
import os
from typing import Optional

import requests
import unittest

from enum import Enum, auto
from datetime import datetime, timedelta
from pathlib import Path


class HttpMethod(Enum):
    Delete = auto()
    Get = auto()
    Put = auto()
    Post = auto()


class ExpectedType(Enum):
    Binary = auto()
    Dict = auto()
    List = auto()
    Text = auto()


class TestRequests(unittest.TestCase):
    # noinspection PyPep8Naming
    def __init__(self, methodName="runTest"):
        super().__init__(methodName)

        self.default_port = 9095
        self.default_host = "localhost"
        self.port = os.getenv("LIZMAP_PORT", self.default_port)
        self.host = os.getenv("LIZMAP_HOST", self.default_host)
        self.base_url = f'http://{self.host}:{self.port}/gobsapi.php/'
        self.api_token = None
        self.maxDiff = None

    @staticmethod
    def get_header(
            content_type: str = None, token: str = None, request_sync_date: str = None,
            last_sync_date: str = None
    ) -> dict:
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

    def login(self, username: str = 'admin', password: str = 'admin') -> None:
        """ Login and get token """
        url = 'user/login'
        params = {
            'username': username,
            'password': password,
        }
        headers = self.get_header(
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
        self, entry_point: str, test_file: Optional[str], method: HttpMethod = HttpMethod.Get,
        params: dict = None, data_file: str = None,
        expected_format: ExpectedType = ExpectedType.Dict, expected_status_code: int = 200,
        content_type: str = None, token_required: bool = True,
        request_sync_date: str = None, last_sync_date: str = None
    ):
        """
        Wrapper which test an api call against test data
        """
        if params is None:
            params = {}
        if not self.api_token and token_required:
            pass

        # Send request
        url = self.base_url + entry_point
        headers = self.get_header(
            content_type=content_type,
            token=self.api_token,
            request_sync_date=request_sync_date,
            last_sync_date=last_sync_date
        )

        if method == HttpMethod.Get:
            response = requests.get(url, params=params, headers=headers)
        elif method in (HttpMethod.Post, HttpMethod.Put):
            # We must send data read from the data_file path
            json_content = None
            files_content = None
            response = None
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
                if method == HttpMethod.Post:
                    response = requests.post(
                        url, params=params, headers=headers,
                        json=json_content, files=files_content
                    )
                elif method == HttpMethod.Put:
                    response = requests.put(
                        url, params=params, headers=headers,
                        json=json_content, files=files_content
                    )
        elif method == HttpMethod.Delete:
            response = requests.delete(url, params=params, headers=headers)
        else:
            raise Exception('Unknown HTTP method')

        if response is None:
            raise Exception('Response is not defined')

        # # Log response text to ease debugging
        # if expected_format != ExpectedType.Binary:
        #     print(response.text)

        # Status code
        self.assertEqual(response.status_code, expected_status_code)

        # Compare the JSON contained in the test_file
        # to the request text response
        if test_file:
            if expected_format in (ExpectedType.Dict, ExpectedType.List, ExpectedType.Text):
                with open(Path(__file__).parent.absolute() / test_file) as expected_file:
                    # Where we are running tests from a different host/port
                    test_file_content = expected_file.read()
                    test_file_content = test_file_content.replace(
                        f"{self.default_host}:{self.default_port}",
                        f"{self.host}:{self.port}"
                    )

                    if expected_format == ExpectedType.Text:
                        self.assertEqual(response.text, test_file_content)
                    else:
                        expected_content = json.loads(test_file_content)
                        received_content = json.loads(response.text)
                        if expected_format == ExpectedType.Dict:
                            self.assertDictEqual(received_content, expected_content)
                        elif expected_format == ExpectedType.List:
                            self.assertListEqual(received_content, expected_content)
            elif expected_format == ExpectedType.Binary:
                with open(Path(__file__).parent.absolute() / test_file, mode='rb') as expected_file:
                    self.assertEqual(response.content, expected_file.read())

        # Return the response
        return response

    @staticmethod
    def is_valid_uuid(given_uid):
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
            expected_format=ExpectedType.List,
        )

    def test_logout(self):
        """ Log out """
        # Logout
        self.api_call(
            entry_point='user/logout',
            test_file='data/output_user_logout.json',
            expected_format=ExpectedType.Dict,
        )

        # Get user projects -> expects 401
        self.api_call(
            entry_point='user/projects',
            test_file='data/output_access_token_missing.json',
            expected_format=ExpectedType.Dict,
            expected_status_code=401,
        )

        # Log back in
        self.login('gobsapi_writer', 'al_password')

    def test_project_unknown(self):
        """ Get details of a nonexistent project """
        project_key = 'gobsapi~foobar'
        self.api_call(
            entry_point=f'/project/{project_key}',
            test_file='data/output_project_unknown.json',
            expected_format=ExpectedType.Dict,
            expected_status_code=404,
        )

    def test_project_details(self):
        """ Get details of the gobsapi project """
        project_key = 'test_project_a'
        self.api_call(
            entry_point=f'/project/{project_key}',
            test_file='data/output_project_details.json',
            expected_format=ExpectedType.Dict
        )

    def test_project_indicators(self):
        """ Get the project indicators """
        project_key = 'test_project_a'
        self.api_call(
            entry_point=f'/project/{project_key}/indicators',
            test_file='data/output_project_indicators.json',
            expected_format=ExpectedType.List
        )

    def test_project_geopackage(self):
        """ Get the Geopackage of a project """
        project_key = 'test_project_a'
        self.api_call(
            entry_point=f'/project/{project_key}/geopackage',
            test_file='data/output_project_geopackage.gpkg',
            expected_format=ExpectedType.Binary
        )

    def test_indicator_details(self):
        """ Get details of the indicator """
        project_key = 'test_project_a'
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
        project_key = 'test_project_a'
        indicator_key = 'hiker_position'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method=HttpMethod.Post,
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
            method=HttpMethod.Post,
            content_type='application/json',
            data_file='data/input_observation_create.json',
            test_file=None,
            expected_status_code=400
        )

        # Delete this observation to be idempotent
        project_key = 'test_project_a'
        indicator_key = 'hiker_position'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            method=HttpMethod.Delete,
            expected_format=ExpectedType.Dict
        )

        # Delete again -> should have a 404
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file='data/output_observation_does_not_exist.json',
            expected_format=ExpectedType.Dict,
            method=HttpMethod.Delete,
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
            expected_format=ExpectedType.List
        )
        json_response = json.loads(response.text)
        self.assertTrue((observation_uuid in json_response))

    def test_observation_create_with_spatial_layer_and_object(self):
        """
        Create an obs without coordinates or wkt
        but with an existing spatial object and spatial layer
        """
        project_key = 'test_project_a'
        indicator_key = 'population'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method=HttpMethod.Post,
            content_type='application/json',
            data_file='data/input_observation_create_with_spatial_object.json',
            test_file=None,
        )

        # Check the data is not empty
        self.assertTrue(len(response.text))

        # Check the returned observation contains expected data
        json_response = json.loads(response.text)

        # Check the returned observation contains expected data
        self.assertEqual(json_response['indicator'], 'population')
        self.assertEqual(json_response['start_timestamp'], '2011-01-01 00:00:00')
        self.assertEqual(json_response['coordinates']['x'], -3.76560994319688)
        self.assertEqual(json_response['coordinates']['y'], 48.402962147635)

        # Check UID is valid
        observation_uuid = json_response['uuid']
        self.assertTrue(self.is_valid_uuid(observation_uuid))

        # Delete this observation to be idempotent
        project_key = 'test_project_a'
        indicator_key = 'population'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            method=HttpMethod.Delete,
            expected_format=ExpectedType.Dict
        )

    def test_indicator_document(self):
        """ Get an indicator document by uid """
        project_key = 'test_project_a'
        indicator_key = 'hiker_position'
        document_uid = '1a7f7323-6b18-46ed-a9fe-9efbe1f006a2'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/document/{document_uid}',
            test_file='data/output_indicator_document_text_file.txt',
            expected_format=ExpectedType.Text,
        )

    def test_indicator_preview(self):
        """ Get an indicator document by uid """
        project_key = 'test_project_a'
        indicator_key = 'hiker_position'
        document_uid = '542aa72f-d1de-4810-97bb-208f2388698b'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/document/{document_uid}',
            test_file='data/output_indicator_document_preview.jpg',
            expected_format=ExpectedType.Binary
        )

    def test_indicator_observations_all(self):
        """ Get observations of the indicator population """
        project_key = 'test_project_a'
        indicator_key = 'population'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observations',
            test_file=None,
            expected_format=ExpectedType.List,
        )
        json_response = json.loads(response.text)
        self.assertEqual(len(json_response), 44)

    def test_indicator_observation_detail(self):
        """ Get an observation of the indicator hiker_position """
        project_key = 'test_project_a'
        indicator_key = 'hiker_position'
        observation_uuid = '1adae0cf-0f3b-4af5-bf26-e72c7fde24f2'
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file='data/output_observation_details.json',
            expected_format=ExpectedType.Dict,
        )

    def test_observation_update(self):
        """ Create an observation & test media upload, download, deletion """
        # Create a new observation
        project_key = 'test_project_a'
        indicator_key = 'hiker_position'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method=HttpMethod.Post,
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
        # Uid must be replaced in the template file
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
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method=HttpMethod.Put,
            content_type='application/json',
            data_file=dynamic_update_file_path,
            test_file=None,
        )

        # Get observation back
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            expected_format=ExpectedType.Dict,
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
            method=HttpMethod.Delete,
            expected_format=ExpectedType.Dict
        )

    def test_observation_media_actions(self):
        """ Create an observation & test media upload, download, deletion """
        # Create a new observation
        project_key = 'test_project_a'
        indicator_key = 'hiker_position'
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
            method=HttpMethod.Post,
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
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}/uploadMedia',
            method=HttpMethod.Post,
            content_type='multipart/form-data',
            data_file='data/input_observation_media_file.jpg',
            test_file='data/output_observation_upload_media_success.json',
        )

        # Get observation back with the URL
        response = self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            expected_format=ExpectedType.Dict,
        )
        observation = json.loads(response.text)
        expected_url = (
            f'{self.base_url }project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}/media'
        )
        self.assertEqual(observation['media_url'], expected_url)

        # Delete the media
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}/deleteMedia',
            method=HttpMethod.Delete,
            test_file='data/output_observation_delete_media_success.json',
            expected_format=ExpectedType.Dict,
        )

        # Delete this observation to be idempotent
        self.api_call(
            entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation/{observation_uuid}',
            test_file=None,
            method=HttpMethod.Delete,
            expected_format=ExpectedType.Dict
        )


if __name__ == "__main__":
    unittest.main()
