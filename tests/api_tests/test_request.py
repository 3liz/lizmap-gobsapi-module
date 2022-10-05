#! /usr/bin/env python

from pathlib import Path

import json
import unittest
import requests


class TestRequests(unittest.TestCase):

    # noinspection PyPep8Naming
    def __init__(self, methodName="runTest"):
        super().__init__(methodName)

        self.base_url = 'http://localhost:9095/gobsapi.php/'
        self.api_token = None

    def getHeader(self, accepted_mime='application/json', token=None):
        """ Set request header """
        headers = {
            'Accept': accepted_mime
        }
        if token:
            headers['Authorization'] = 'Bearer {}'.format(token)

        return headers

    def setUp(self) -> None:
        """ Login as admin and set the token """
        self.login('admin', 'admin')

    def login(self, username='admin', password='admin') -> None:
        """ Login and get token """
        url = 'user/login'
        params = {
            'username': 'admin',
            'password': 'admin',
        }
        headers = self.getHeader()
        req = requests.get(self.base_url + url, params=params, headers=headers)
        if req.status_code != 200:
            return

        content = json.loads(req.text)
        if 'token' not in content:
            return

        self.api_token = content['token']
        print("TOKEN = {}".format(self.api_token))

    def api_call(
        self, entry_point, test_file,
        expected_format='dict', expected_status_code=200,
        accepted_mime='application/json', token_required=True
    ):
        """ Wrapper which test an api call against test data"""
        if not self.api_token and token_required:
            print('Token required: abort')
            pass

        # Send request
        url = self.base_url + entry_point
        params = {}
        headers = self.getHeader(accepted_mime, self.api_token)
        req = requests.get(url, params=params, headers=headers)

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
            'user/projects',
            'data/user_projects.json',
            'list'
        )

    def test_logout(self):
        """ Log out """
        # Logout
        self.api_call(
            'user/logout',
            'data/user_logout.json',
            'dict'
        )

        # Get user projects -> expects 401
        self.api_call(
            'user/projects',
            'data/access_token_missing.json',
            'dict',
            401
        )

        # Log back in
        self.login()

    def test_project_unknown(self):
        """ Get details of an unexistent project """
        project_key = 'gobsapi~foobar'
        self.api_call(
            f'/project/{project_key}',
            'data/project_unknown.json',
            'dict',
            404
        )

    def test_project_details(self):
        """ Get details of the gobsapi project """
        project_key = 'gobsapi~gobsapi'
        self.api_call(
            f'/project/{project_key}',
            'data/project_details.json',
            'dict'
        )

    def test_project_indicators(self):
        """ Get the project indicators """
        project_key = 'gobsapi~gobsapi'
        self.api_call(
            f'/project/{project_key}/indicators',
            'data/project_indicators.json',
            'list'
        )

    def test_indicator_details(self):
        """ Get details of the indicator """
        project_key = 'gobsapi~gobsapi'
        indicator_key = 'pluviometry'
        self.api_call(
            f'/project/{project_key}/indicator/{indicator_key}',
            'data/indicator_details.json',
            'dict'
        )


if __name__ == "__main__":
    unittest.main()

# files = {'media': open('test.jpg', 'rb')}
# requests.post(url, files=files)
