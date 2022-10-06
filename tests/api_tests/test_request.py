#! /usr/bin/env python

import json
import unittest
from datetime import datetime

import requests


class TestRequests(unittest.TestCase):
    # noinspection PyPep8Naming
    def __init__(self, methodName="runTest"):
        super().__init__(methodName)

        self.base_url = 'http://localhost:9095/gobsapi.php/'
        self.api_token = None

    def getHeader(self, accepted_mime='application/json', token=None, request_sync_date=None, last_sync_date=None):
        """ Set request header """
        headers = {
            'Accept': accepted_mime
        }
        if token:
            headers['Authorization'] = 'Bearer {}'.format(token)

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
        headers = self.getHeader()
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
        accepted_mime='application/json', token_required=True,
        request_sync_date=None, last_sync_date=None
    ):
        """ Wrapper which test an api call against test data"""
        if not self.api_token and token_required:
            print('Token required: abort')
            pass

        # Send request
        url = self.base_url + entry_point
        headers = self.getHeader(accepted_mime, self.api_token, request_sync_date, last_sync_date)
        # files = {'media': open('test.jpg', 'rb')}
        # requests.post(url, files=files)

        if method == 'get':
            req = requests.get(url, params=params, headers=headers)
        elif method == 'post':
            # get data
            data = None
            if data_file:
                with open(data_file) as json_file:
                    data = json.load(json_file)
            req = requests.post(url, params=params, headers=headers, data=data)

        # Status code
        self.assertEqual(req.status_code, expected_status_code)

        # Get JSON test data
        with open(test_file) as json_file:
            data = json.load(json_file)
            if expected_format == 'dict':
                self.assertDictEqual(json.loads(req.text), data)
            elif expected_format == 'list':
                self.assertListEqual(json.loads(req.text), data)
            else:
                self.assertEqual(json.loads(req.text), data)

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

    # def test_observation_create(self):
    #     """ Create an observation """
    #     project_key = 'gobsapi~gobsapi'
    #     indicator_key = 'hiker_position'
    #     self.api_call(
    #         entry_point=f'/project/{project_key}/indicator/{indicator_key}/observation',
    #         method='post',
    #         data_file='data/input_observation_create.json',
    #         test_file='data/output_observation_create.json',
    #     )

    # def test_indicator_observations(self):
    #     """ Get details of the indicator """
    #     project_key = 'gobsapi~gobsapi'
    #     indicator_key = 'hiker_position'
    #     self.api_call(
    #         entry_point=f'/project/{project_key}/indicator/{indicator_key}/observations',
    #         test_file='data/output_indicator_details.json',
    #         expected_format='dict'
    #     )


if __name__ == "__main__":
    unittest.main()
