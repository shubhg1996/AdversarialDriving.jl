@with_kw mutable struct Agent
    initial_entity::Entity # The initial entity
    model::DriverModel # The driver model associated with this agent
    num_obs::Int # The number of observations for this agent
    to_vec::Function # A Function that converts the agent to a vector of length num_obs
    to_entity::Union{Function, Nothing} = nothing # A Function that converts a vector of length num_obs to an entity
    actions::Array{Disturbance} = [] # List of possible actions for this agent (adversaries only)
    action_prob::Array{Float64} = [] # the associated action probabilities
end

id(a::Agent) = a.initial_entity.id

# Construct a regular Blinker vehicle agent
function BlinkerVehicleAgent(veh::Entity{BlinkerState, D, I}, model::TIDM; num_obs = BLINKERVEHICLE_OBS, to_vec = BlinkerVehicle_to_vec, to_entity = vec_to_BlinkerVehicle, actions = BV_ACTIONS, action_prob = BV_ACTION_PROB) where {D,I}
    Agent(veh, model, num_obs, to_vec, to_entity, actions, action_prob)
end

# Construct a regular adversarial pedestrian agent
function NoisyPedestrianAgent(ped::Entity{NoisyPedState, D, I}, model::AdversarialPedestrian; num_obs = PEDESTRIAN_OBS, to_vec = NoisyPedestrian_to_vec, to_entity = vec_to_NoisyPedestrian_fn(DEFAULT_CROSSWALK_LANE)) where {D, I}
    Agent(ped, model, num_obs, to_vec, to_entity, [], [])
end

# Definition of the adversarial driving mdp
mutable struct AdversarialDrivingMDP <: MDP{Scene, Array{Disturbance}}
    agents::Array{Agent} # All the agents ordered by veh_id
    vehid2ind::Dict{Int64, Int64} # Dictionary that maps vehid to index in agent list
    num_adversaries::Int64 # The number of adversaries
    roadway::Roadway # The roadway for the simulation
    initial_scene::Scene # Initial scene
    dt::Float64 # Simulation timestep
    last_observation::Array{Float64} # Last observation of the vehicle state
    actions::Array{Array{Disturbance}} # Set of all actions for the mdp
    action_to_index::Dict{Array{Disturbance}, Int64} # Dictionary mapping actions to index
    action_probabilities::Array{Float64} # probability of taking each action
    γ::Float64 # discount
end

# Constructor
function AdversarialDrivingMDP(sut::Agent, adversaries::Array{Agent}, road::Roadway, dt::Float64; discrete = true, other_agents::Array{Agent} = Agent[], γ = 1)
    agents = [adversaries..., sut, other_agents...]
    d = Dict(id(agents[i]) => i for i=1:length(agents))
    Na = length(adversaries)
    scene = Scene([a.initial_entity for a in agents])
    o = Float64[] # Last observation

    as, a2i, aprob = discrete ? construct_discrete_actions(adversaries) : (Array{Disturbance}[], Dict{Array{Disturbance}, Int64}(), Float64[])
    AdversarialDrivingMDP(agents, d, Na, road, scene, dt, o, as, a2i, aprob, γ)
end

# Returns the intial state of the mdp simulator
POMDPs.initialstate(mdp::AdversarialDrivingMDP, rng::AbstractRNG = Random.GLOBAL_RNG) = mdp.initial_scene

# The generative interface to the POMDP
function POMDPs.gen(mdp::AdversarialDrivingMDP, s::Scene, a::Array{Disturbance}, rng::Random.AbstractRNG = Random.GLOBAL_RNG)
    sp = step_scene(mdp, s, a, rng)
    r = reward(mdp, s, a, sp)
    (sp=sp, r=r)
end

# Get the reward from the actions taken and the next state
function POMDPs.reward(mdp::AdversarialDrivingMDP, s::Scene, a::Array{Disturbance}, sp::Scene)
    Float64(length(sp) > 0 && ego_collides(sutid(mdp), sp))
end

# Discount factor for the POMDP (Set to 1 because of the finite horizon)
POMDPs.discount(mdp::AdversarialDrivingMDP) = mdp.γ

# The simulation is terminal if there is collision with the ego vehicle or if the maximum simulation time has been reached
POMDPs.isterminal(mdp::AdversarialDrivingMDP, s::Scene) = length(s) == 0 || any_collides(s)

# Define the set of actions, action index and probability
POMDPs.actions(mdp::AdversarialDrivingMDP) = mdp.actions
POMDPs.actions(mdp::AdversarialDrivingMDP, state::Tuple{Scene, Float64}) = actions(mdp)
POMDPs.actionindex(mdp::AdversarialDrivingMDP, a::Array{Disturbance}) = mdp.action_to_index[a]
action_probability(mdp::AdversarialDrivingMDP, a::Array{Disturbance}) = mdp.action_probabilities[mdp.action_to_index[a]]
action_probability(mdp::AdversarialDrivingMDP, s::Scene, a::Array{Disturbance}) = action_probability(mdp, a)


## Helper functions

# Step the scene forward by one timestep and return the next state
function step_scene(mdp::AdversarialDrivingMDP, s::Scene, actions::Array{Disturbance}, rng::AbstractRNG = Random.GLOBAL_RNG)
    entities = []

    # Loop through the adversaries and apply the instantaneous aspects of their disturbance
    for (adversary, action) in zip(adversaries(mdp), actions)
        update_adversary!(adversary, action, s)
    end

    # Loop through the vehicles in the scene, apply action and add to next scene
    for (i, veh) in enumerate(s)
        m = model(mdp, veh.id)
        observe!(m, s, mdp.roadway, veh.id)
        a = rand(rng, m)
        bv = Entity(propagate(veh, a, mdp.roadway, mdp.dt), veh.def, veh.id)
        !end_of_road(bv, mdp.roadway) && push!(entities, bv)
    end
    isempty(entities) ? Scene(typeof(sut(mdp).initial_entity)) : Scene([entities...])
end

# Returns the list of agents in the mdp
agents(mdp::AdversarialDrivingMDP) = mdp.agents

# Returns the list of adversaries in the mdp
adversaries(mdp::AdversarialDrivingMDP) = view(mdp.agents, 1:mdp.num_adversaries)

# Returns the model associated with the vehid
model(mdp::AdversarialDrivingMDP, vehid::Int) = mdp.agents[mdp.vehid2ind[vehid]].model

# Returns the system under test
sut(mdp::AdversarialDrivingMDP) = mdp.agents[mdp.num_adversaries + 1]

# Returns the sut id
sutid(mdp::AdversarialDrivingMDP) = id(sut(mdp))

function update_adversary!(adversary::Agent, action::Disturbance, s::Scene)
    index = findfirst(id(adversary), s)
    isnothing(index) && return nothing # If the adversary is not in the scene then don't update
    adversary.model.next_action = action # Set the adversaries next action
    veh = s[index] # Get the actual entity
    state_type = typeof(veh.state) # Find out the type of its state
    s[index] =  Entity(state_type(veh.state, noise = action.noise), veh.def, veh.id) # replace the entity in the scene
end
