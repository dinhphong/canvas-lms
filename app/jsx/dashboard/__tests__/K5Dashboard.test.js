/*
 * Copyright (C) 2021 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import React from 'react'
import moxios from 'moxios'
import {act, render, waitForElement, within} from '@testing-library/react'
import {K5Dashboard} from '../K5Dashboard'
import fetchMock from 'fetch-mock'

const currentUser = {
  id: '1',
  display_name: 'Geoffrey Jellineck'
}
const cardSummary = [
  {
    type: 'Conversation',
    unread_count: 1,
    count: 3
  }
]
const dashboardCards = [
  {
    id: 'test',
    assetString: 'course_1',
    href: '/courses/1',
    shortName: 'Econ 101',
    originalName: 'Economics 101',
    courseCode: 'ECON-001',
    isHomeroom: false
  },
  {
    id: 'homeroom',
    assetString: 'course_2',
    href: '/courses/2',
    shortName: 'Homeroom',
    originalName: 'Home Room',
    courseCode: 'HOME-001',
    isHomeroom: true
  }
]
const defaultEnv = {
  current_user: currentUser,
  FEATURES: {
    canvas_for_elementary: true,
    unpublished_courses: true
  },
  PREFERENCES: {
    hide_dashcard_color_overlays: false
  },
  MOMENT_LOCALE: 'en',
  TIMEZONE: 'America/Denver'
}
const defaultProps = {
  currentUser,
  env: defaultEnv,
  plannerEnabled: false
}

const getSelectedTab = wrapper => {
  const selectedTabs = wrapper.getAllByRole('tab').filter(tab => tab.getAttribute('aria-selected'))
  expect(selectedTabs.length).toBe(1)
  return selectedTabs[0]
}

const expectSelectedTabText = (wrapper, text) => {
  const tab = getSelectedTab(wrapper)
  expect(within(tab).getByText(text)).toBeInTheDocument()
}

// We often have to wait for the Dashboard cards to be rendered on the Homeroom
// tab, otherwise the test finishes too early and Jest cleans up the context
// passed to the card components (e.g. window.ENV). This causes the test to fail
// with undefined errors even if the actual test really succeeds.
const waitForCardsToLoad = async wrapper => {
  await waitForElement(() => wrapper.getByTestId('k5-dashboard-card'))
}

const renderDashboardHomeroomPage = async (props = defaultProps) => {
  const wrapper = render(<K5Dashboard {...props} />)
  await waitForCardsToLoad(wrapper)
  return wrapper
}

beforeAll(() => {
  moxios.install()
  moxios.stubRequest('/api/v1/dashboard/dashboard_cards', {
    status: 200,
    response: dashboardCards
  })
  moxios.stubRequest(/\/api\/v1\/planner\/items.*/, {
    status: 200,
    response: [],
    headers: {
      link: ''
    }
  })
  fetchMock.get('/api/v1/courses/test/activity_stream/summary', JSON.stringify(cardSummary))
  fetchMock.get(
    '/api/v1/courses/homeroom/discussion_topics?only_announcements=true&per_page=1',
    '[]'
  )
  fetchMock.get('/api/v1/courses/test/discussion_topics?only_announcements=true&per_page=1', '[]')
  fetchMock.get('/api/v1/users/self/missing_submissions?filter[]=submittable', '[]')
})

afterAll(() => {
  moxios.uninstall()
  fetchMock.restore()
})

beforeEach(() => {
  jest.resetModules()
  global.ENV = defaultEnv
})

afterEach(() => {
  global.ENV = {}
})

describe('K-5 Dashboard', () => {
  it('displays a welcome message to the logged-in user', async () => {
    const wrapper = await renderDashboardHomeroomPage()

    expect(wrapper.getByText('Welcome, Geoffrey Jellineck!')).toBeInTheDocument()
  })

  describe('Tabs', () => {
    it('show Homeroom, Schedule, Grades, and Resources options', async () => {
      const wrapper = await renderDashboardHomeroomPage()
      ;['Homeroom', 'Schedule', 'Grades', 'Resources'].forEach(label => {
        expect(wrapper.getByText(label)).toBeInTheDocument()
      })
    })

    it('default to the Homeroom tab', async () => {
      const wrapper = await renderDashboardHomeroomPage()

      expectSelectedTabText(wrapper, 'Homeroom')
    })

    describe('store current tab ID to URL', () => {
      afterEach(() => {
        window.location.hash = ''
      })

      it('and start at that tab if it is valid', async () => {
        window.location.hash = '#grades'
        let wrapper = null
        await act(async () => {
          wrapper = await render(<K5Dashboard {...defaultProps} />)
        })

        expectSelectedTabText(wrapper, 'Grades')
      })

      it('and start at the default tab if it is invalid', async () => {
        window.location.hash = 'tab-not-a-real-tab'
        const wrapper = await renderDashboardHomeroomPage()

        expectSelectedTabText(wrapper, 'Homeroom')
      })

      it('and update the current tab as tabs are changed', async () => {
        const wrapper = await renderDashboardHomeroomPage()

        await act(async () => within(wrapper.getByRole('tablist')).getByText('Grades').click())
        expect(window.location.hash).toBe('#grades')
        expectSelectedTabText(wrapper, 'Grades')

        await act(async () => within(wrapper.getByRole('tablist')).getByText('Resources').click())
        expect(window.location.hash).toBe('#resources')
        expectSelectedTabText(wrapper, 'Resources')
      })
    })
  })

  describe('Homeroom Section', () => {
    it('displays "My Subjects" heading', async () => {
      const wrapper = await renderDashboardHomeroomPage()
      expect(wrapper.getByText('My Subjects')).toBeInTheDocument()
    })

    it('shows course cards, excluding homerooms', async () => {
      const wrapper = await renderDashboardHomeroomPage()
      expect(wrapper.getByText('Economics 101')).toBeInTheDocument()
      expect(wrapper.queryByText('Home Room')).toBeNull()
    })
  })

  describe('Schedule Section', () => {
    it('displays an empty state when no items are fetched', async () => {
      const {getByText} = render(
        <K5Dashboard {...defaultProps} defaultTab="tab-schedule" plannerEnabled />
      )
      await waitForElement(() => getByText("Looks like there isn't anything here"))
    })
  })
})
