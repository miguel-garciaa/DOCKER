import { queryParams, type RouteQueryOptions, type RouteDefinition, type RouteFormDefinition } from './../../wayfinder'
/**
* @see \Livewire\Mechanisms\HandleRequests\HandleRequests::update
 * @see vendor/livewire/livewire/src/Mechanisms/HandleRequests/HandleRequests.php:153
 * @route '/livewire-46639414/update'
 */
export const update = (options?: RouteQueryOptions): RouteDefinition<'post'> => ({
    url: update.url(options),
    method: 'post',
})

update.definition = {
    methods: ["post"],
    url: '/livewire-46639414/update',
} satisfies RouteDefinition<["post"]>

/**
* @see \Livewire\Mechanisms\HandleRequests\HandleRequests::update
 * @see vendor/livewire/livewire/src/Mechanisms/HandleRequests/HandleRequests.php:153
 * @route '/livewire-46639414/update'
 */
update.url = (options?: RouteQueryOptions) => {
    return update.definition.url + queryParams(options)
}

/**
* @see \Livewire\Mechanisms\HandleRequests\HandleRequests::update
 * @see vendor/livewire/livewire/src/Mechanisms/HandleRequests/HandleRequests.php:153
 * @route '/livewire-46639414/update'
 */
update.post = (options?: RouteQueryOptions): RouteDefinition<'post'> => ({
    url: update.url(options),
    method: 'post',
})

    /**
* @see \Livewire\Mechanisms\HandleRequests\HandleRequests::update
 * @see vendor/livewire/livewire/src/Mechanisms/HandleRequests/HandleRequests.php:153
 * @route '/livewire-46639414/update'
 */
    const updateForm = (options?: RouteQueryOptions): RouteFormDefinition<'post'> => ({
        action: update.url(options),
        method: 'post',
    })

            /**
* @see \Livewire\Mechanisms\HandleRequests\HandleRequests::update
 * @see vendor/livewire/livewire/src/Mechanisms/HandleRequests/HandleRequests.php:153
 * @route '/livewire-46639414/update'
 */
        updateForm.post = (options?: RouteQueryOptions): RouteFormDefinition<'post'> => ({
            action: update.url(options),
            method: 'post',
        })
    
    update.form = updateForm
const defaultLivewire = {
    update: Object.assign(update, update),
}

export default defaultLivewire