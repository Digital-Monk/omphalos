"""Thaumaturgy - Custom spell design"""
from game.magic.spells import Spell


class Thaumaturgy:
    """Thaumaturgy system - design custom spells"""
    
    def __init__(self, player_stats):
        """
        Initialize thaumaturgy system
        
        Args:
            player_stats: PlayerStats object
        """
        self.player_stats = player_stats
    
    def design_spell(self, name, energy_types, effect_type, radius, power):
        """
        Design a custom spell
        
        Args:
            name: Spell name
            energy_types: List of energy types to combine
            effect_type: Effect pattern
            radius: Effect radius
            power: Effect strength
            
        Returns:
            Spell object if successful, None if too complex
        """
        # Check complexity
        complexity = len(energy_types)
        max_complexity = self.player_stats.get_spell_complexity()
        
        if complexity > max_complexity:
            return None
        
        # Calculate base cost
        base_cost = (radius * power * complexity) / 10
        
        # Combine energy types (use first for now, can be extended)
        primary_energy = energy_types[0] if energy_types else "magic"
        
        # Create the spell
        spell = Spell(
            name=name,
            energy_type=primary_energy,
            effect_type=effect_type,
            radius=radius,
            power=power,
            cost=base_cost
        )
        
        return spell
    
    def create_scroll(self, spell):
        """
        Create a scroll from a spell
        Costs magic upfront
        
        Args:
            spell: Spell to embed in scroll
            
        Returns:
            Scroll object if successful
        """
        from game.magic.spells import Scroll
        
        creation_cost = spell.cost * 2  # Creating scroll costs 2x the spell cost
        
        if self.player_stats.use_magic(creation_cost):
            return Scroll(spell)
        return None
    
    def add_to_spellbook(self, spell, spellbook):
        """
        Add a spell to a spellbook
        No magic cost, but others pay full cost
        
        Args:
            spell: Spell to add
            spellbook: Spellbook to add to
            
        Returns:
            True if successful
        """
        design_cost = spell.cost * 0.5  # Designing for spellbook costs 0.5x
        
        if self.player_stats.use_magic(design_cost):
            spellbook.add_spell(spell)
            return True
        return False
    
    def enchant_object(self, spell, object_data):
        """
        Enchant an object with a spell
        
        Args:
            spell: Spell to embed
            object_data: Object to enchant
            
        Returns:
            Enchanted object data
        """
        enchantment_cost = spell.cost * 3  # Permanent enchantment costs 3x
        
        if self.player_stats.use_magic(enchantment_cost):
            object_data['enchantment'] = spell.to_dict()
            return object_data
        return None
