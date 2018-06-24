# Reading Instructions

This chapter is a reading guide to the requirements.

## Cursive text

Cursive text in a requirement is a definition.
The explanation for the definition can be found under the [Definitions chapter](#Definitions).

## Assertions
(copied from the Artifact git repo)

Assertions **will** be used throughout the artifacts to mean:
- shall: the statement must be implemented and it's
    implementation verified.
- will: statement of fact, not subject to verification.
    I.e. "The X system will have timing as defined in ICD 1234"
- should: goals, non-mandatory provisions. Statements using "should"
    **should** be verified if possible, but verification is not mandatory if
    not possible. Is a statement of intent.

## Risks
(copied from the Artifact git repo)
See [artifact security threat analysis](https://github.com/vitiral/artifact/blob/master/design/security.toml) for an example.

Risks are to be written with three sets of terms in mind:
- likelihood
- impact
- product placement

Likelihood has three categories:
 1. low
 2. medium
 3. high

Impact has five categories:
 1. sand
 2. pebble
 3. rock
 4. boulder
 5. avalanche

Product placement has three categories:
 1. cosmetic
 3. necessary
 5. critical

The value of these three categories will be multiplied to
determine the weight to assign to the risk.

> sand may seem small, but if you have enough sand in your
> gears, you aren't going anywhere.
>
> You definitely need to watch out for boulders and prevent
> avalanches whenever possible
