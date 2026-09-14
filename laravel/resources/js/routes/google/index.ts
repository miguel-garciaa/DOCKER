import { queryParams, type RouteQueryOptions, type RouteDefinition, type RouteFormDefinition } from './../../wayfinder'
/**
* @see \App\Http\Controllers\GoogleAuthController::redirect
 * @see app/Http/Controllers/GoogleAuthController.php:15
 * @route '/auth/google'
 */
export const redirect = (options?: RouteQueryOptions): RouteDefinition<'get'> => ({
    url: redirect.url(options),
    method: 'get',
})

redirect.definition = {
    methods: ["get","head"],
    url: '/auth/google',
} satisfies RouteDefinition<["get","head"]>

/**
* @see \App\Http\Controllers\GoogleAuthController::redirect
 * @see app/Http/Controllers/GoogleAuthController.php:15
 * @route '/auth/google'
 */
redirect.url = (options?: RouteQueryOptions) => {
    return redirect.definition.url + queryParams(options)
}

/**
* @see \App\Http\Controllers\GoogleAuthController::redirect
 * @see app/Http/Controllers/GoogleAuthController.php:15
 * @route '/auth/google'
 */
redirect.get = (options?: RouteQueryOptions): RouteDefinition<'get'> => ({
    url: redirect.url(options),
    method: 'get',
})
/**
* @see \App\Http\Controllers\GoogleAuthController::redirect
 * @see app/Http/Controllers/GoogleAuthController.php:15
 * @route '/auth/google'
 */
redirect.head = (options?: RouteQueryOptions): RouteDefinition<'head'> => ({
    url: redirect.url(options),
    method: 'head',
})

    /**
* @see \App\Http\Controllers\GoogleAuthController::redirect
 * @see app/Http/Controllers/GoogleAuthController.php:15
 * @route '/auth/google'
 */
    const redirectForm = (options?: RouteQueryOptions): RouteFormDefinition<'get'> => ({
        action: redirect.url(options),
        method: 'get',
    })

            /**
* @see \App\Http\Controllers\GoogleAuthController::redirect
 * @see app/Http/Controllers/GoogleAuthController.php:15
 * @route '/auth/google'
 */
        redirectForm.get = (options?: RouteQueryOptions): RouteFormDefinition<'get'> => ({
            action: redirect.url(options),
            method: 'get',
        })
            /**
* @see \App\Http\Controllers\GoogleAuthController::redirect
 * @see app/Http/Controllers/GoogleAuthController.php:15
 * @route '/auth/google'
 */
        redirectForm.head = (options?: RouteQueryOptions): RouteFormDefinition<'get'> => ({
            action: redirect.url({
                        [options?.mergeQuery ? 'mergeQuery' : 'query']: {
                            _method: 'HEAD',
                            ...(options?.query ?? options?.mergeQuery ?? {}),
                        }
                    }),
            method: 'get',
        })
    
    redirect.form = redirectForm
/**
* @see \App\Http\Controllers\GoogleAuthController::callback
 * @see app/Http/Controllers/GoogleAuthController.php:22
 * @route '/auth/google/callback'
 */
export const callback = (options?: RouteQueryOptions): RouteDefinition<'get'> => ({
    url: callback.url(options),
    method: 'get',
})

callback.definition = {
    methods: ["get","head"],
    url: '/auth/google/callback',
} satisfies RouteDefinition<["get","head"]>

/**
* @see \App\Http\Controllers\GoogleAuthController::callback
 * @see app/Http/Controllers/GoogleAuthController.php:22
 * @route '/auth/google/callback'
 */
callback.url = (options?: RouteQueryOptions) => {
    return callback.definition.url + queryParams(options)
}

/**
* @see \App\Http\Controllers\GoogleAuthController::callback
 * @see app/Http/Controllers/GoogleAuthController.php:22
 * @route '/auth/google/callback'
 */
callback.get = (options?: RouteQueryOptions): RouteDefinition<'get'> => ({
    url: callback.url(options),
    method: 'get',
})
/**
* @see \App\Http\Controllers\GoogleAuthController::callback
 * @see app/Http/Controllers/GoogleAuthController.php:22
 * @route '/auth/google/callback'
 */
callback.head = (options?: RouteQueryOptions): RouteDefinition<'head'> => ({
    url: callback.url(options),
    method: 'head',
})

    /**
* @see \App\Http\Controllers\GoogleAuthController::callback
 * @see app/Http/Controllers/GoogleAuthController.php:22
 * @route '/auth/google/callback'
 */
    const callbackForm = (options?: RouteQueryOptions): RouteFormDefinition<'get'> => ({
        action: callback.url(options),
        method: 'get',
    })

            /**
* @see \App\Http\Controllers\GoogleAuthController::callback
 * @see app/Http/Controllers/GoogleAuthController.php:22
 * @route '/auth/google/callback'
 */
        callbackForm.get = (options?: RouteQueryOptions): RouteFormDefinition<'get'> => ({
            action: callback.url(options),
            method: 'get',
        })
            /**
* @see \App\Http\Controllers\GoogleAuthController::callback
 * @see app/Http/Controllers/GoogleAuthController.php:22
 * @route '/auth/google/callback'
 */
        callbackForm.head = (options?: RouteQueryOptions): RouteFormDefinition<'get'> => ({
            action: callback.url({
                        [options?.mergeQuery ? 'mergeQuery' : 'query']: {
                            _method: 'HEAD',
                            ...(options?.query ?? options?.mergeQuery ?? {}),
                        }
                    }),
            method: 'get',
        })
    
    callback.form = callbackForm
const google = {
    redirect: Object.assign(redirect, redirect),
callback: Object.assign(callback, callback),
}

export default google