using POMDPs

const OBS_PER_VEH = 4
const OBS_PER_VEH_EXPANDED = 30
const ACT_PER_VEH = 7
const Atype = Array{LaneFollowingAccelBlinker}

mutable struct AdversarialADM <: MDP{Scene, Atype}
    num_vehicles # The number of vehicles represented in the state and action spaces
    num_controllable_vehicles # Number of vehicles that will be part of the action space
    models # The models for the simulation
    roadway # The roadway for the simulation
    egoid # The id of the ego vehicle
    initial_scene # Initial scene
    dt # Simulation timestep
    last_observation # Last observation of the vehicle state
    actions # Set of all actions for the pomdp
    action_to_index # Dictionary mapping actions to dictionary
    action_probabilities # probability of taking each action
end

function AdversarialADM(models, roadway, egoid, intial_scene, dt)
    num_vehicles = length(intial_scene)
    num_controllable_vehicles = num_vehicles - 1

    # This code makes it so that one car at a time can make one of its actions
    actions = Array{Atype}(undef, num_controllable_vehicles*(ACT_PER_VEH-1) + 1)
    action_to_index = Dict()
    action_probabilities = Array{Float64}(undef, num_controllable_vehicles*(ACT_PER_VEH-1) + 1)
    index = 1

    # First select the action where all of the cars do nothing
    do_nothing_action = [index_to_action(1) for i in 1:num_controllable_vehicles]
    actions[index] = do_nothing_action
    action_to_index[do_nothing_action] = index
    action_probabilities[index] = action_probability(1)
    index += 1

    # Then loop through all vehicles and give each one the possibilities of doing an action
    for vehid in 1:num_controllable_vehicles
        for aid in 2:ACT_PER_VEH # Skip the do-nothing action
            a = [index_to_action(1) for i in 1:num_controllable_vehicles]
            a[vehid] = index_to_action(aid)
            actions[index] = a
            action_to_index[a] = index
            action_probabilities[index] = action_probability(aid) / num_controllable_vehicles
            index += 1
        end
    end
    action_probabilities = action_probabilities ./ sum(action_probabilities)
    @assert sum(action_probabilities) == 1

    # This code makes it so all vehicles can choose an action at one time
    # actions = Array{Atype}(undef, a_dim(num_controllable_vehicles))
    # action_to_index = Dict()
    # index = 1
    # for ijk in CartesianIndices(Tuple(ACT_PER_VEH for i=1:num_controllable_vehicles))
    #     a = [index_to_action(ijk.I[i], models[i]) for i in 1:num_controllable_vehicles]
    #     actions[index] = a
    #     action_to_index[a] = index
    #     index += 1
    # end
    AdversarialADM(num_vehicles, num_controllable_vehicles, models, roadway, egoid, intial_scene, dt, zeros(num_vehicles*OBS_PER_VEH), actions, action_to_index, action_probabilities)
end

o_dim(pomdp::AdversarialADM) = pomdp.num_vehicles*OBS_PER_VEH
a_dim(num_controllable_vehicles::Int) = ACT_PER_VEH^num_controllable_vehicles
a_dim(pomdp::AdversarialADM) = a_dim(pomdp.num_controllable_vehicles)


function index_to_action(action::Int)
    action == 1 && return LaneFollowingAccelBlinker(0, 0., false, false)
    action == 2 && return LaneFollowingAccelBlinker(0, -3., false, false)
    action == 3 && return LaneFollowingAccelBlinker(0, -1.5, false, false)
    action == 4 && return LaneFollowingAccelBlinker(0, 1.5, false, false)
    action == 5 && return LaneFollowingAccelBlinker(0, 3., false, false)
    action == 6 && return LaneFollowingAccelBlinker(0, 0., true, false) # toggle goal
    action == 7 && return LaneFollowingAccelBlinker(0, 0., false, true) # toggle blinker
end

function action_probability(action::Int)
    action == 1 && return 1 - (4e-3 + 2e-2) # This is the nominal do-nothing action
    action == 2 && return 1e-3
    action == 3 && return 1e-2
    action == 4 && return 1e-2
    action == 5 && return 1e-3
    action == 6 && return 1e-3
    action == 7 && return 1e-3
end


function action_to_string(action::Int)
    action == 1 && return "do nothing"
    action == 2 && return "hard brake"
    action == 3 && return "soft brake"
    action == 4 && return "soft acc"
    action == 5 && return "hard acc"
    action == 6 && return "toggle goal"
    action == 7 && return "toggle blinker"
end


POMDPs.actions(pomdp::AdversarialADM) = pomdp.actions
POMDPs.actions(pomdp::AdversarialADM, state::Tuple{Scene, Float64}) = actions(pomdp)
POMDPs.actionindex(pomdp::AdversarialADM, a::Atype) = pomdp.action_to_index[a]

action_probability(pomdp::AdversarialADM, s::Scene, a::Atype) = 1. / length(pomdp.actions)

true_action_probability(pomdp::AdversarialADM, s::Scene, a::Atype) = pomdp.action_probabilities[pomdp.action_to_index[a]]
    # prod([exp(action_logprob(pomdp.models[i], a[i])) for i in 1:pomdp.num_controllable_vehicles])

random_action(pomdp::AdversarialADM, s::Scene, rng::AbstractRNG) = pomdp.actions[rand(rng, Categorical(pomdp.action_probabilities))]

# Gets an action according to true probabilities of the agents
# function random_action(pomdp::AdversarialADM, s::Scene, rng::Random.AbstractRNG)
#     as = fill(LaneFollowingAccelBlinker(0,0,false,false), pomdp.num_vehicles)
#     for (i, veh) in enumerate(s)
#         model = pomdp.models[veh.id]
#         observe!(model, s, pomdp.roadway, veh.id)
#         a = rand(rng, model, ignore_force = true)
#         as[veh.id] = a
#     end
#     as
# end

# Converts from vector to state
function POMDPs.convert_s(::Type{Scene}, s::AbstractArray{Float64}, pomdp::AdversarialADM)
    new_scene = Scene(BlinkerVehicle)
    Nveh = Int(length(s) / OBS_PER_VEH)

    # Loop through the vehicles in the scene, apply action and add to next scene
    for i = 1:Nveh
        j = (i-1)*OBS_PER_VEH + 1
        d = s[j] # Distance along the lane
        v = s[j+1] # velocity
        g = s[j+2] # Goal (lane id)
        b = s[j+3] # blinker

        laneid = Int(g)
        lane = pomdp.roadway[laneid].lanes[1]
        blinker = Bool(b)
        vs = VehicleState(Frenet(lane, d, 0.), pomdp.roadway, v)
        bv = BlinkerVehicle(BlinkerState(vs, blinker, pomdp.models[i].goals[laneid]), VehicleDef(), i)

        if !end_of_road(bv, pomdp.roadway)
            push!(new_scene, bv)
        end
    end
    new_scene
end

# Converts the state of a blinker vehicle to a vector
function to_vec(veh::BlinkerVehicle)
    Float64[posf(veh.state).s,
            vel(veh.state),
            laneid(veh),
            veh.state.blinker]
end

function one_hot(i, N)
    v = zeros(N)
    v[i] = 1
    v
end

# Converts the state of a blinker vehicle to an expanded state space representation
function to_expanded_vec(veh::BlinkerVehicle)
    oh = one_hot(laneid(veh), 6)
    s = posf(veh.state).s .* oh
    v = vel(veh.state) .* oh
    v2 = v.^2
    b = veh.state.blinker .* oh
    Float64[oh..., s..., v..., v2..., b...]
end

# Convert from state to vector (this one is simple )
function POMDPs.convert_s(::Type{Array{Float64, 1}}, state::Scene, pomdp::AdversarialADM)
    o = deepcopy(pomdp.last_observation)
    for (ind,veh) in enumerate(state)
        o[(veh.id-1)*OBS_PER_VEH + 1: veh.id*OBS_PER_VEH] .= to_vec(veh)
    end
    pomdp.last_observation = o
    o
end

POMDPs.convert_s(::Type{AbstractArray}, state::Scene, pomdp::AdversarialADM) = convert_s(Array{Float64,1}, state, pomdp)
POMDPs.convert_s(::Type{AbstractArray}, state::Scene, pomdp::AdversarialADM) = convert_s(Array{Float64,1}, state, pomdp)

function convert_s_expanded(::Type, state::Scene, pomdp::AdversarialADM)
    v = zeros(OBS_PER_VEH_EXPANDED*pomdp.num_vehicles)
    for (ind,veh) in enumerate(state)
        v[(veh.id-1)*OBS_PER_VEH_EXPANDED + 1: veh.id*OBS_PER_VEH_EXPANDED] .= to_expanded_vec(veh)
    end
    v
end


# Returns the intial state of the pomdp simulator
POMDPs.initialstate(pomdp::AdversarialADM, rng::AbstractRNG = Random.GLOBAL_RNG) = pomdp.initial_scene

# Returns a deterministic distribution to be sampled by a simulator
POMDPs.initialstate_distribution(pomdp::AdversarialADM) = Deterministic(pomdp.initial_scene)

# Get the reward from the actions taken and the next state
POMDPs.reward(pomdp::AdversarialADM, s::Scene, a::Atype, sp::Scene) = iscollision(pomdp, sp)

# Step the scene forward by one timestep and return the next state
function step_scene(pomdp::AdversarialADM, s::Scene, actions::Atype, rng::AbstractRNG = Random.GLOBAL_RNG)
    new_scene = Scene(BlinkerVehicle)

    # Loop through the vehicles in the scene, apply action and add to next scene
    for (i, veh) in enumerate(s)
        model = pomdp.models[veh.id]
        observe!(model, s, pomdp.roadway, veh.id)

        # Set the forced actions of the model
        if model.force_action
            action = actions[veh.id]
            model.da_force = action.da
            model.toggle_goal_force = action.toggle_goal
            model.toggle_blinker_force = action.toggle_blinker
        end

        a = rand(rng, pomdp.models[veh.id])
        vs_p = propagate(veh, a, pomdp.roadway, pomdp.dt)
        bv = BlinkerVehicle(vs_p, veh.def, veh.id)

        if !end_of_road(bv, pomdp.roadway)
            push!(new_scene, bv)
        end
    end

    return new_scene
end

POMDPs.gen(::DDNOut{(:sp, :r)}, mdp::AdversarialADM, s::Scene, a::Atype, rng::AbstractRNG = Random.GLOBAL_RNG) = gen(mdp, s, a, rng)


# The generative interface to the POMDP
function POMDPs.gen(pomdp::AdversarialADM, s::Scene, a::Atype, rng::Random.AbstractRNG = Random.GLOBAL_RNG)
    # Simulate the scene forward one timestep
    # Try to use the existing simulate function
    sp = step_scene(pomdp, s, a, rng)

    # Get the reward
    r = reward(pomdp, s, a, sp)

    # Extract the observations
    # o = convert_s(Array{Float64,1}, sp, pomdp)

    # Return
    (sp=sp, r=r)
end

# Discount factor for the POMDP (Set to 1 because of the finite horizon)
POMDPs.discount(pomdp::AdversarialADM) = 1.

# Check if there is a collision with the ego vehicle in the scene
iscollision(pomdp::AdversarialADM, s::Scene) = length(s) > 0 && ego_collides(pomdp.egoid, s)

# The simulation is terminal if there is collision with the ego vehicle or if the maximum simulation time has been reached
function POMDPs.isterminal(pomdp::AdversarialADM, s::Scene)
    length(s) == 0 || iscollision(pomdp, s) || any_collides(s)
end

function fixed_action_rollout(pomdp::AdversarialADM, actions::Array{Atype}, rng::AbstractRNG = Random.GLOBAL_RNG)
    s = initialstate(pomdp)
    state_hist = [s]
    i = 1
    tot_r = 0
    prob = 0
    while !POMDPs.isterminal(pomdp, s)
        a = (i <= length(actions)) ? actions[i] : random_action(pomdp, s, rng)
        prob += true_action_probability(pomdp, s, a)
        s, r = gen(DDNOut((:sp, :r)), pomdp, s, a, rng)
        tot_r += r
        i += 1
        push!(state_hist, s)
    end
    return state_hist, prob / (i-1), tot_r
end

