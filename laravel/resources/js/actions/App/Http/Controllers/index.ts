import GoogleAuthController from './GoogleAuthController'
import Settings from './Settings'
const Controllers = {
    GoogleAuthController: Object.assign(GoogleAuthController, GoogleAuthController),
Settings: Object.assign(Settings, Settings),
}

export default Controllers